// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Vm} from "forge-std/Test.sol";

import {TimeLockVaults} from "../../src/TimeLockVaults.sol";
import {ITimeLockVaults} from "../../src/interfaces/ITimeLockVaults.sol";
import {GuardianPausable} from "../../src/utils/GuardianPausable.sol";
import {TokenTransfer} from "../../src/utils/TokenTransfer.sol";
import {MockERC7579Account} from "../mocks/MockERC7579Account.sol";
import {CallbackToken, FeeOnTransferToken} from "../mocks/TestTokens.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract TimeLockVaultsTest is BaseTest {
    TimeLockVaults internal vaults;
    Vm.Wallet internal ownerKey;
    Vm.Wallet internal sessionKey;
    address internal account = makeAddr("parent-account");
    uint64 internal unlockAt;

    uint256 internal constant AMOUNT = 5000 * USDC_UNIT;

    function setUp() public override {
        super.setUp();
        vaults = new TimeLockVaults(guardian);
        ownerKey = vm.createWallet("vault-owner");
        sessionKey = vm.createWallet("agent-session-key");
        unlockAt = uint64(block.timestamp + 180 days);
    }

    // ------------------------------------------------------------------ helpers

    function _create(address owner) internal returns (uint256 id) {
        vm.prank(account);
        id = vaults.createVault(address(usdc), unlockAt, owner);
    }

    function _deposit(uint256 id, address from, uint256 amount) internal {
        _fundAndApprove(from, address(vaults), amount);
        vm.prank(from);
        vaults.deposit(id, amount);
    }

    function _earlySig(uint256 pk, uint256 id, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(pk, vaults.earlyWithdrawalDigest(id, amount, nonce, deadline));
    }

    function _ownerSig(uint256 pk, uint256 id, address newOwner, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(pk, vaults.setOwnerDigest(id, newOwner, nonce, deadline));
    }

    // ------------------------------------------------------------------ create / deposit

    function test_createVault_storesAndEmits() public {
        vm.expectEmit(true, true, true, true, address(vaults));
        emit ITimeLockVaults.VaultCreated(1, account, ownerKey.addr, address(usdc), unlockAt);
        uint256 id = _create(ownerKey.addr);
        assertEq(id, 1);
        assertEq(vaults.vaultCount(), 1);
        ITimeLockVaults.Vault memory v = vaults.getVault(id);
        assertEq(v.account, account);
        assertEq(v.owner, ownerKey.addr);
        assertEq(v.token, address(usdc));
        assertEq(v.unlockAt, unlockAt);
        assertEq(v.balance, 0);
        assertEq(v.nonce, 0);
        assertEq(vaults.vaultAccount(id), account);
        assertEq(vaults.vaultAccount(999), address(0));
    }

    function test_createVault_reverts() public {
        vm.startPrank(account);
        vm.expectRevert(ITimeLockVaults.ZeroAddress.selector);
        vaults.createVault(address(0), unlockAt, ownerKey.addr);
        vm.expectRevert(abi.encodeWithSelector(ITimeLockVaults.InvalidOwner.selector, address(0)));
        vaults.createVault(address(usdc), unlockAt, address(0));
        vm.expectRevert(abi.encodeWithSelector(ITimeLockVaults.InvalidOwner.selector, account));
        vaults.createVault(address(usdc), unlockAt, account);
        vm.expectRevert(abi.encodeWithSelector(ITimeLockVaults.InvalidOwner.selector, address(vaults)));
        vaults.createVault(address(usdc), unlockAt, address(vaults));
        uint64 nowTs = uint64(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ITimeLockVaults.InvalidUnlockTime.selector, nowTs));
        vaults.createVault(address(usdc), nowTs, ownerKey.addr);
        uint64 tooFar = nowTs + 3650 days + 1;
        vm.expectRevert(abi.encodeWithSelector(ITimeLockVaults.InvalidUnlockTime.selector, tooFar));
        vaults.createVault(address(usdc), tooFar, ownerKey.addr);
        vm.stopPrank();
    }

    function test_deposit_anyoneCanFundTheAccountsVault() public {
        uint256 id = _create(ownerKey.addr);
        _fundAndApprove(stranger, address(vaults), AMOUNT);
        vm.expectEmit(true, true, false, true, address(vaults));
        emit ITimeLockVaults.Deposited(id, stranger, AMOUNT, AMOUNT);
        vm.prank(stranger);
        vaults.deposit(id, AMOUNT);
        _deposit(id, account, AMOUNT);
        assertEq(vaults.getVault(id).balance, 2 * AMOUNT);
        assertEq(vaults.totalHeld(address(usdc)), 2 * AMOUNT);
        assertEq(usdc.balanceOf(address(vaults)), 2 * AMOUNT);
    }

    function test_deposit_reverts() public {
        uint256 id = _create(ownerKey.addr);
        vm.expectRevert(abi.encodeWithSelector(ITimeLockVaults.VaultNotFound.selector, 7));
        vaults.deposit(7, 1);
        vm.expectRevert(ITimeLockVaults.InvalidAmount.selector);
        vaults.deposit(id, 0);
    }

    function test_deposit_rejectsFeeOnTransferToken() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        vm.prank(account);
        uint256 id = vaults.createVault(address(fot), unlockAt, ownerKey.addr);
        fot.mint(stranger, 1000);
        vm.startPrank(stranger);
        fot.approve(address(vaults), 1000);
        vm.expectRevert(abi.encodeWithSelector(TokenTransfer.TransferAmountMismatch.selector, address(fot), 1000, 990));
        vaults.deposit(id, 1000);
        vm.stopPrank();
    }

    function test_pause_blocksDepositsOnly() public {
        uint256 id = _create(ownerKey.addr);
        _deposit(id, account, AMOUNT);
        vm.prank(guardian);
        vaults.pause();

        _fundAndApprove(stranger, address(vaults), 1);
        vm.prank(stranger);
        vm.expectRevert(GuardianPausable.NewDepositsPaused.selector);
        vaults.deposit(id, 1);

        // creating vaults and every withdrawal path still work
        _create(ownerKey.addr);
        uint256 deadline = block.timestamp + 1 hours;
        vaults.withdrawWithSignature(id, 1, deadline, _earlySig(ownerKey.privateKey, id, 1, 0, deadline));
        vm.warp(unlockAt);
        vaults.withdraw(id, AMOUNT - 1);
        assertEq(usdc.balanceOf(account), AMOUNT);
    }

    // ------------------------------------------------------------------ withdraw after unlock

    function test_withdraw_onlyAfterUnlock_toParentAccount_byAnyone() public {
        uint256 id = _create(ownerKey.addr);
        _deposit(id, stranger, AMOUNT);

        vm.warp(unlockAt - 1);
        vm.expectRevert(abi.encodeWithSelector(ITimeLockVaults.StillLocked.selector, id, unlockAt));
        vaults.withdraw(id, 1);

        vm.warp(unlockAt);
        vm.expectEmit(true, true, true, true, address(vaults));
        emit ITimeLockVaults.Withdrawn(id, account, stranger, 1000, false);
        vm.prank(stranger);
        vaults.withdraw(id, 1000);
        assertEq(usdc.balanceOf(account), 1000, "always to the parent account");
        assertEq(usdc.balanceOf(stranger), 0);

        vm.prank(keeper);
        vaults.withdraw(id, AMOUNT - 1000);
        assertEq(usdc.balanceOf(account), AMOUNT);
        assertEq(vaults.getVault(id).balance, 0);
        assertEq(vaults.totalHeld(address(usdc)), 0);
    }

    function test_withdraw_reverts() public {
        uint256 id = _create(ownerKey.addr);
        _deposit(id, stranger, AMOUNT);
        vm.warp(unlockAt);
        vm.expectRevert(ITimeLockVaults.InvalidAmount.selector);
        vaults.withdraw(id, 0);
        vm.expectRevert(
            abi.encodeWithSelector(ITimeLockVaults.InsufficientVaultBalance.selector, id, AMOUNT + 1, AMOUNT)
        );
        vaults.withdraw(id, AMOUNT + 1);
        vm.expectRevert(abi.encodeWithSelector(ITimeLockVaults.VaultNotFound.selector, 3));
        vaults.withdraw(3, 1);
    }

    // ------------------------------------------------------------------ early withdrawal (owner signature)

    function test_withdrawWithSignature_eoaOwner() public {
        uint256 id = _create(ownerKey.addr);
        _deposit(id, stranger, AMOUNT);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _earlySig(ownerKey.privateKey, id, 2000, 0, deadline);

        vm.expectEmit(true, true, true, true, address(vaults));
        emit ITimeLockVaults.Withdrawn(id, account, keeper, 2000, true);
        vm.prank(keeper); // any relayer may submit; funds still go to the account
        vaults.withdrawWithSignature(id, 2000, deadline, sig);
        assertEq(usdc.balanceOf(account), 2000);
        assertEq(vaults.getVault(id).nonce, 1);

        // replay fails: the nonce moved
        vm.expectRevert(ITimeLockVaults.InvalidSignature.selector);
        vaults.withdrawWithSignature(id, 2000, deadline, sig);
    }

    function test_withdrawWithSignature_rejectsWrongSignerAmountOrExpiry() public {
        uint256 id = _create(ownerKey.addr);
        _deposit(id, stranger, AMOUNT);
        uint256 deadline = block.timestamp + 1 days;

        // signed by the agent's session key instead of the owner
        bytes memory agentSig = _earlySig(sessionKey.privateKey, id, 1, 0, deadline);
        vm.expectRevert(ITimeLockVaults.InvalidSignature.selector);
        vaults.withdrawWithSignature(id, 1, deadline, agentSig);

        // signed amount differs from the submitted amount
        bytes memory amountSig = _earlySig(ownerKey.privateKey, id, 1, 0, deadline);
        vm.expectRevert(ITimeLockVaults.InvalidSignature.selector);
        vaults.withdrawWithSignature(id, 2, deadline, amountSig);

        // signed for another vault
        uint256 other = _create(ownerKey.addr);
        bytes memory otherVaultSig = _earlySig(ownerKey.privateKey, other, 1, 0, deadline);
        vm.expectRevert(ITimeLockVaults.InvalidSignature.selector);
        vaults.withdrawWithSignature(id, 1, deadline, otherVaultSig);

        // malformed signature
        vm.expectRevert(ITimeLockVaults.InvalidSignature.selector);
        vaults.withdrawWithSignature(id, 1, deadline, hex"1234");

        // expired (deadline inclusive)
        bytes memory sig = _earlySig(ownerKey.privateKey, id, 1, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ITimeLockVaults.SignatureExpired.selector, deadline));
        vaults.withdrawWithSignature(id, 1, deadline, sig);
    }

    function test_withdrawWithSignature_deadlineIsInclusive() public {
        uint256 id = _create(ownerKey.addr);
        _deposit(id, stranger, AMOUNT);
        uint256 deadline = block.timestamp + 10;
        bytes memory sig = _earlySig(ownerKey.privateKey, id, 1, 0, deadline);
        vm.warp(deadline);
        vaults.withdrawWithSignature(id, 1, deadline, sig);
        assertEq(usdc.balanceOf(account), 1);
    }

    /// @notice Agents act through the parent account. Even if the account's ERC-1271 accepts the agent's key,
    ///         the vault owner is a different address, so the agent cannot unlock savings early.
    function test_agentCannotWithdrawEarly_evenWithAccountErc1271() public {
        MockERC7579Account smartAccount = new MockERC7579Account(entryPoint, makeAddr("principal"));
        vm.prank(smartAccount.owner());
        smartAccount.ownerExecute(
            address(smartAccount), 0, abi.encodeCall(MockERC7579Account.setErc1271Signer, (sessionKey.addr, true))
        );

        vm.prank(address(smartAccount));
        uint256 id = vaults.createVault(address(usdc), unlockAt, ownerKey.addr);
        _deposit(id, stranger, AMOUNT);

        uint256 deadline = block.timestamp + 1 days;
        bytes memory agentSig = _earlySig(sessionKey.privateKey, id, AMOUNT, 0, deadline);
        assertEq(
            smartAccount.isValidSignature(vaults.earlyWithdrawalDigest(id, AMOUNT, 0, deadline), agentSig),
            bytes4(0x1626ba7e),
            "the account itself would vouch for the agent"
        );
        vm.expectRevert(ITimeLockVaults.InvalidSignature.selector);
        vaults.withdrawWithSignature(id, AMOUNT, deadline, agentSig);

        // and the account can never be made the owner
        vm.prank(address(smartAccount));
        vm.expectRevert(abi.encodeWithSelector(ITimeLockVaults.InvalidOwner.selector, address(smartAccount)));
        vaults.createVault(address(usdc), unlockAt, address(smartAccount));
    }

    /// @notice Contract owners (e.g. a Safe or passkey signer) authorise through ERC-1271.
    function test_withdrawWithSignature_erc1271Owner() public {
        MockERC7579Account ownerSafe = new MockERC7579Account(entryPoint, ownerKey.addr);
        uint256 id = _create(address(ownerSafe));
        _deposit(id, stranger, AMOUNT);
        uint256 deadline = block.timestamp + 1 days;

        vaults.withdrawWithSignature(id, 500, deadline, _earlySig(ownerKey.privateKey, id, 500, 0, deadline));
        assertEq(usdc.balanceOf(account), 500);

        bytes memory strangerSig = _earlySig(sessionKey.privateKey, id, 500, 1, deadline);
        vm.expectRevert(ITimeLockVaults.InvalidSignature.selector);
        vaults.withdrawWithSignature(id, 500, deadline, strangerSig);
    }

    function test_withdrawWithSignature_insufficientBalance() public {
        uint256 id = _create(ownerKey.addr);
        _deposit(id, stranger, 10);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _earlySig(ownerKey.privateKey, id, 11, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(ITimeLockVaults.InsufficientVaultBalance.selector, id, 11, 10));
        vaults.withdrawWithSignature(id, 11, deadline, sig);
    }

    // ------------------------------------------------------------------ owner changes

    function test_setOwner_requiresCurrentOwnerSignature() public {
        uint256 id = _create(ownerKey.addr);
        _deposit(id, stranger, AMOUNT);
        Vm.Wallet memory newOwner = vm.createWallet("new-owner");
        uint256 deadline = block.timestamp + 1 days;

        bytes memory agentSig = _ownerSig(sessionKey.privateKey, id, newOwner.addr, 0, deadline);
        vm.expectRevert(ITimeLockVaults.InvalidSignature.selector);
        vaults.setOwner(id, newOwner.addr, deadline, agentSig);

        vm.expectEmit(true, true, true, true, address(vaults));
        emit ITimeLockVaults.OwnerChanged(id, ownerKey.addr, newOwner.addr);
        vaults.setOwner(id, newOwner.addr, deadline, _ownerSig(ownerKey.privateKey, id, newOwner.addr, 0, deadline));
        assertEq(vaults.getVault(id).owner, newOwner.addr);
        assertEq(vaults.getVault(id).nonce, 1);

        // the old owner lost its power; the new one has it
        bytes memory oldOwnerSig = _earlySig(ownerKey.privateKey, id, 1, 1, deadline);
        vm.expectRevert(ITimeLockVaults.InvalidSignature.selector);
        vaults.withdrawWithSignature(id, 1, deadline, oldOwnerSig);
        vaults.withdrawWithSignature(id, 1, deadline, _earlySig(newOwner.privateKey, id, 1, 1, deadline));
    }

    function test_setOwner_resigningSameOwnerInvalidatesOutstandingSignature() public {
        uint256 id = _create(ownerKey.addr);
        _deposit(id, stranger, AMOUNT);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory pending = _earlySig(ownerKey.privateKey, id, AMOUNT, 0, deadline);

        vaults.setOwner(id, ownerKey.addr, deadline, _ownerSig(ownerKey.privateKey, id, ownerKey.addr, 0, deadline));
        vm.expectRevert(ITimeLockVaults.InvalidSignature.selector);
        vaults.withdrawWithSignature(id, AMOUNT, deadline, pending);
    }

    function test_setOwner_reverts() public {
        uint256 id = _create(ownerKey.addr);
        uint256 deadline = block.timestamp + 1 days;
        vm.expectRevert(abi.encodeWithSelector(ITimeLockVaults.InvalidOwner.selector, address(0)));
        vaults.setOwner(id, address(0), deadline, "");
        vm.expectRevert(abi.encodeWithSelector(ITimeLockVaults.InvalidOwner.selector, account));
        vaults.setOwner(id, account, deadline, "");
        vm.expectRevert(abi.encodeWithSelector(ITimeLockVaults.InvalidOwner.selector, address(vaults)));
        vaults.setOwner(id, address(vaults), deadline, "");
        bytes memory sig = _ownerSig(ownerKey.privateKey, id, stranger, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ITimeLockVaults.SignatureExpired.selector, deadline));
        vaults.setOwner(id, stranger, deadline, sig);
        vm.expectRevert(abi.encodeWithSelector(ITimeLockVaults.VaultNotFound.selector, 42));
        vaults.setOwner(42, stranger, deadline, sig);
    }

    // ------------------------------------------------------------------ EIP-712

    function test_eip712_digestsMatchSpec() public view {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("AgentBank TimeLockVaults"),
                keccak256("1"),
                block.chainid,
                address(vaults)
            )
        );
        assertEq(vaults.DOMAIN_SEPARATOR(), domain);
        bytes32 early = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domain,
                keccak256(
                    abi.encode(
                        keccak256("EarlyWithdrawal(uint256 vaultId,uint256 amount,uint256 nonce,uint256 deadline)"),
                        uint256(1),
                        uint256(2),
                        uint256(3),
                        uint256(4)
                    )
                )
            )
        );
        assertEq(vaults.earlyWithdrawalDigest(1, 2, 3, 4), early);
        bytes32 setOwner = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domain,
                keccak256(
                    abi.encode(
                        keccak256("SetOwner(uint256 vaultId,address newOwner,uint256 nonce,uint256 deadline)"),
                        uint256(1),
                        stranger,
                        uint256(3),
                        uint256(4)
                    )
                )
            )
        );
        assertEq(vaults.setOwnerDigest(1, stranger, 3, 4), setOwner);
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            vaults.eip712Domain();
        assertEq(name, "AgentBank TimeLockVaults");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(vaults));
    }

    // ------------------------------------------------------------------ reentrancy

    function test_reentrancy_tokenCallbackCannotReenter() public {
        CallbackToken cbk = new CallbackToken();
        vm.prank(account);
        uint256 id = vaults.createVault(address(cbk), unlockAt, ownerKey.addr);
        cbk.mint(stranger, 1000);
        vm.prank(stranger);
        cbk.approve(address(vaults), 1000);
        vm.prank(stranger);
        vaults.deposit(id, 500);

        vm.warp(unlockAt);
        cbk.setCallback(address(vaults), abi.encodeCall(TimeLockVaults.withdraw, (id, 1)));
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vaults.withdraw(id, 100);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_withdraw_onlyEverToAccount(uint256 deposited, uint256 withdrawn, uint32 elapsed) public {
        deposited = bound(deposited, 1, 1e15);
        withdrawn = bound(withdrawn, 1, deposited);
        uint256 id = _create(ownerKey.addr);
        _deposit(id, stranger, deposited);
        vm.warp(block.timestamp + elapsed);
        vm.prank(stranger);
        if (block.timestamp < unlockAt) {
            vm.expectRevert(abi.encodeWithSelector(ITimeLockVaults.StillLocked.selector, id, unlockAt));
            vaults.withdraw(id, withdrawn);
        } else {
            vaults.withdraw(id, withdrawn);
            assertEq(usdc.balanceOf(account), withdrawn);
            assertEq(usdc.balanceOf(stranger), 0);
            assertEq(vaults.getVault(id).balance, deposited - withdrawn);
        }
    }

    function testFuzz_withdrawWithSignature_onlyOwnerKeyWorks(uint256 signerPk, uint256 amount) public {
        signerPk = bound(
            signerPk,
            1,
            115_792_089_237_316_195_423_570_985_008_687_907_852_837_564_279_074_904_382_605_163_141_518_161_494_336
        );
        amount = bound(amount, 1, AMOUNT);
        uint256 id = _create(ownerKey.addr);
        _deposit(id, stranger, AMOUNT);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _earlySig(signerPk, id, amount, 0, deadline);
        if (vm.addr(signerPk) == ownerKey.addr) {
            vaults.withdrawWithSignature(id, amount, deadline, sig);
            assertEq(usdc.balanceOf(account), amount);
        } else {
            vm.expectRevert(ITimeLockVaults.InvalidSignature.selector);
            vaults.withdrawWithSignature(id, amount, deadline, sig);
        }
    }
}
