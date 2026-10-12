// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";

interface ISafeRecoveryTarget {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool);
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) external view returns (bytes32);
    function nonce() external view returns (uint256);
    function enableModule(address module) external;
    function isModuleEnabled(address module) external view returns (bool);
    function getOwners() external view returns (address[] memory);
    function isOwner(address owner) external view returns (bool);
    function getThreshold() external view returns (uint256);
}

interface ISafeFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

/// @dev Candide SocialRecoveryModule v0.0.1 (Ackee-audited), as deployed on Base Sepolia.
interface ISocialRecoveryModule {
    struct RecoveryRequest {
        uint256 guardiansApprovalCount;
        uint256 newThreshold;
        uint64 executeAfter;
        address[] newOwners;
    }

    function NAME() external view returns (string memory);
    function VERSION() external view returns (string memory);
    function addGuardianWithThreshold(address guardian, uint256 threshold) external;
    function confirmRecovery(address wallet, address[] calldata newOwners, uint256 newThreshold, bool execute) external;
    function executeRecovery(address wallet, address[] calldata newOwners, uint256 newThreshold) external;
    function finalizeRecovery(address wallet) external;
    function cancelRecovery() external;
    function invalidateNonce() external;
    function getRecoveryRequest(address wallet) external view returns (RecoveryRequest memory);
    function getRecoveryApprovals(address wallet, address[] calldata newOwners, uint256 newThreshold)
        external
        view
        returns (uint256);
    function isGuardian(address wallet, address guardian) external view returns (bool);
    function guardiansCount(address wallet) external view returns (uint256);
    function threshold(address wallet) external view returns (uint256);
}

/// @title Guardian recovery on Base Sepolia with Candide's audited SocialRecoveryModule (ADR 0002).
/// @notice A 1-of-1 Safe (the principal's owner key) enables the 3-day (72 h) SocialRecoveryModule with three guardians
///         (two chosen by the principal plus Agent Bank) and a threshold of 2. Proves: two guardians rotate the owner key
///         after 72 h; Agent Bank alone cannot; the current owner can cancel during the delay; pending confirmations can
///         be invalidated; Agent Bank can never become an owner through recovery.
/// @dev Runs only under `FOUNDRY_PROFILE=fork`; skips cleanly when the RPC is unreachable.
contract CandideSocialRecoveryForkTest is Test {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 internal constant DEFAULT_FORK_BLOCK = 47_990_000;

    /// @dev Candide SocialRecoveryModule, 3-day recovery period (same address on every supported chain).
    ISocialRecoveryModule internal constant RECOVERY =
        ISocialRecoveryModule(0x38275826E1933303E508433dD5f289315Da2541c);
    uint256 internal constant RECOVERY_DELAY = 72 hours;

    ISafeFactory internal constant SAFE_PROXY_FACTORY = ISafeFactory(0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67);
    address internal constant SAFE_L2_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant COMPATIBILITY_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    bool internal forkAvailable;
    ISafeRecoveryTarget internal safe;
    Vm.Wallet internal owner;
    Vm.Wallet internal newOwner;
    address internal guardian1;
    address internal guardian2;
    address internal bankGuardian;
    address internal keeper;

    function setUp() public {
        string memory rpcUrl = vm.envOr("BASE_SEPOLIA_RPC_URL", string("https://sepolia.base.org"));
        uint256 forkBlock = vm.envOr("BASE_SEPOLIA_FORK_BLOCK", DEFAULT_FORK_BLOCK);
        if (forkBlock == 0) {
            try vm.createSelectFork(rpcUrl) returns (uint256) {
                forkAvailable = true;
            } catch {
                return;
            }
        } else {
            try vm.createSelectFork(rpcUrl, forkBlock) returns (uint256) {
                forkAvailable = true;
            } catch {
                return;
            }
        }
        assertEq(block.chainid, BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_RPC_URL is not Base Sepolia");

        owner = vm.createWallet("recovery.owner");
        newOwner = vm.createWallet("recovery.new-owner");
        guardian1 = makeAddr("recovery.guardian-family");
        guardian2 = makeAddr("recovery.guardian-hardware-key");
        bankGuardian = makeAddr("recovery.guardian-agent-bank");
        keeper = makeAddr("recovery.keeper");

        address[] memory owners = new address[](1);
        owners[0] = owner.addr;
        bytes memory initializer = abi.encodeCall(
            ISafeRecoveryTarget.setup,
            (owners, 1, address(0), "", COMPATIBILITY_FALLBACK_HANDLER, address(0), 0, payable(address(0)))
        );
        safe = ISafeRecoveryTarget(SAFE_PROXY_FACTORY.createProxyWithNonce(SAFE_L2_SINGLETON, initializer, 7));

        // Owner-signed configuration: enable the module, then add guardians (the last call fixes threshold = 2).
        _ownerExec(address(safe), abi.encodeCall(ISafeRecoveryTarget.enableModule, (address(RECOVERY))));
        _ownerExec(address(RECOVERY), abi.encodeCall(ISocialRecoveryModule.addGuardianWithThreshold, (guardian1, 1)));
        _ownerExec(address(RECOVERY), abi.encodeCall(ISocialRecoveryModule.addGuardianWithThreshold, (guardian2, 2)));
        _ownerExec(address(RECOVERY), abi.encodeCall(ISocialRecoveryModule.addGuardianWithThreshold, (bankGuardian, 2)));
    }

    modifier onlyFork() {
        if (!forkAvailable) vm.skip(true, "Base Sepolia RPC unreachable");
        _;
    }

    // =====================================================================================================
    // Configuration
    // =====================================================================================================

    function test_fork_moduleIsCandideV001_andConfigMatchesPolicy() public onlyFork {
        assertEq(RECOVERY.NAME(), "Social Recovery Module");
        assertEq(RECOVERY.VERSION(), "0.0.1");
        assertTrue(safe.isModuleEnabled(address(RECOVERY)));
        assertEq(RECOVERY.guardiansCount(address(safe)), 3);
        assertEq(RECOVERY.threshold(address(safe)), 2);
        assertTrue(RECOVERY.isGuardian(address(safe), bankGuardian));
        // Policy (ADR 0002): threshold is a strict majority, and Agent Bank's single seat is below it.
        assertGt(RECOVERY.threshold(address(safe)) * 2, RECOVERY.guardiansCount(address(safe)));
        assertLt(uint256(1), RECOVERY.threshold(address(safe)));
    }

    // =====================================================================================================
    // Recovery paths
    // =====================================================================================================

    function test_fork_twoGuardiansRotateOwnerAfter72Hours() public onlyFork {
        address[] memory newOwners = _single(newOwner.addr);
        vm.prank(guardian1);
        RECOVERY.confirmRecovery(address(safe), newOwners, 1, false);
        vm.prank(guardian2);
        RECOVERY.confirmRecovery(address(safe), newOwners, 1, true); // threshold reached: the 72 h clock starts

        ISocialRecoveryModule.RecoveryRequest memory request = RECOVERY.getRecoveryRequest(address(safe));
        assertEq(request.executeAfter, block.timestamp + RECOVERY_DELAY, "72 h delay");
        assertEq(request.guardiansApprovalCount, 2);

        vm.warp(request.executeAfter - 1);
        vm.expectRevert(bytes("SM: recovery period still pending"));
        RECOVERY.finalizeRecovery(address(safe));

        vm.warp(request.executeAfter);
        vm.prank(keeper); // anyone may finalize once the delay has passed
        RECOVERY.finalizeRecovery(address(safe));

        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1);
        assertEq(owners[0], newOwner.addr);
        assertFalse(safe.isOwner(owner.addr));
        assertEq(safe.getThreshold(), 1);

        // The rotated key now controls the Safe: it can e.g. invalidate pending guardian confirmations.
        _exec(newOwner, address(RECOVERY), abi.encodeCall(ISocialRecoveryModule.invalidateNonce, ()));
    }

    function test_fork_agentBankAloneCannotRecover() public onlyFork {
        address[] memory newOwners = _single(newOwner.addr);
        vm.prank(bankGuardian);
        vm.expectRevert(bytes("SM: confirmed signatures less than threshold"));
        RECOVERY.confirmRecovery(address(safe), newOwners, 1, true);

        vm.prank(bankGuardian);
        RECOVERY.confirmRecovery(address(safe), newOwners, 1, false);
        assertEq(RECOVERY.getRecoveryApprovals(address(safe), newOwners, 1), 1);
        vm.expectRevert(bytes("SM: confirmed signatures less than threshold"));
        RECOVERY.executeRecovery(address(safe), newOwners, 1);

        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(bytes("SM: no ongoing recovery"));
        RECOVERY.finalizeRecovery(address(safe));
        assertTrue(safe.isOwner(owner.addr));
    }

    /// @notice Agent Bank plus one independent guardian can recover, but the owner still sees and can cancel it.
    function test_fork_agentBankNeedsAnIndependentGuardian() public onlyFork {
        address[] memory newOwners = _single(newOwner.addr);
        vm.prank(bankGuardian);
        RECOVERY.confirmRecovery(address(safe), newOwners, 1, false);
        vm.prank(guardian1);
        RECOVERY.confirmRecovery(address(safe), newOwners, 1, true);
        assertGt(RECOVERY.getRecoveryRequest(address(safe)).executeAfter, 0);

        _ownerExec(address(RECOVERY), abi.encodeCall(ISocialRecoveryModule.cancelRecovery, ()));
        vm.warp(block.timestamp + RECOVERY_DELAY);
        vm.expectRevert(bytes("SM: no ongoing recovery"));
        RECOVERY.finalizeRecovery(address(safe));
        assertTrue(safe.isOwner(owner.addr));
    }

    function test_fork_ownerCancelsDuringDelay() public onlyFork {
        address[] memory newOwners = _single(newOwner.addr);
        vm.prank(guardian1);
        RECOVERY.confirmRecovery(address(safe), newOwners, 1, false);
        vm.prank(guardian2);
        RECOVERY.confirmRecovery(address(safe), newOwners, 1, true);
        uint64 executeAfter = RECOVERY.getRecoveryRequest(address(safe)).executeAfter;

        // Neither a guardian nor Agent Bank can cancel; only the wallet itself (its owner's signature) can.
        vm.prank(bankGuardian);
        vm.expectRevert(bytes("SM: no ongoing recovery"));
        RECOVERY.cancelRecovery();

        vm.warp(executeAfter - 1); // last second of the delay
        _ownerExec(address(RECOVERY), abi.encodeCall(ISocialRecoveryModule.cancelRecovery, ()));
        assertEq(RECOVERY.getRecoveryRequest(address(safe)).executeAfter, 0);

        vm.warp(executeAfter + 1 days);
        vm.expectRevert(bytes("SM: no ongoing recovery"));
        RECOVERY.finalizeRecovery(address(safe));
        // The old confirmations are spent (the nonce moved when the recovery started): it cannot simply be replayed.
        vm.expectRevert(bytes("SM: confirmed signatures less than threshold"));
        RECOVERY.executeRecovery(address(safe), newOwners, 1);
        assertTrue(safe.isOwner(owner.addr));
        assertFalse(safe.isOwner(newOwner.addr));
    }

    function test_fork_ownerInvalidatesPendingConfirmations() public onlyFork {
        address[] memory newOwners = _single(newOwner.addr);
        vm.prank(guardian1);
        RECOVERY.confirmRecovery(address(safe), newOwners, 1, false);
        _ownerExec(address(RECOVERY), abi.encodeCall(ISocialRecoveryModule.invalidateNonce, ()));
        vm.prank(guardian2);
        vm.expectRevert(bytes("SM: confirmed signatures less than threshold"));
        RECOVERY.confirmRecovery(address(safe), newOwners, 1, true);
    }

    /// @notice Even colluding guardians cannot hand the Safe to Agent Bank: a guardian can never become an owner.
    function test_fork_agentBankCanNeverBecomeOwner() public onlyFork {
        address[] memory newOwners = _single(bankGuardian);
        vm.prank(guardian1);
        RECOVERY.confirmRecovery(address(safe), newOwners, 1, false);
        vm.prank(guardian2);
        RECOVERY.confirmRecovery(address(safe), newOwners, 1, true);
        vm.warp(block.timestamp + RECOVERY_DELAY);
        vm.expectRevert(bytes("SM: new owner cannot be guardian"));
        RECOVERY.finalizeRecovery(address(safe));
        assertTrue(safe.isOwner(owner.addr));
    }

    // =====================================================================================================
    // Helpers
    // =====================================================================================================

    function _ownerExec(address to, bytes memory data) internal {
        _exec(owner, to, data);
    }

    /// @dev Executes a Safe transaction signed (ECDSA) by `signer`, relayed by the keeper.
    function _exec(Vm.Wallet memory signer, address to, bytes memory data) internal {
        bytes memory signature = _signSafeTx(signer, to, data);
        bytes memory call = abi.encodeCall(
            ISafeRecoveryTarget.execTransaction, (to, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), signature)
        );
        vm.prank(keeper);
        (bool ok, bytes memory ret) = address(safe).call(call);
        assertTrue(ok && abi.decode(ret, (bool)), "Safe transaction failed");
    }

    function _signSafeTx(Vm.Wallet memory signer, address to, bytes memory data) internal view returns (bytes memory) {
        bytes32 txHash = safe.getTransactionHash(to, 0, data, 0, 0, 0, 0, address(0), address(0), safe.nonce());
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer.privateKey, txHash);
        return abi.encodePacked(r, s, v);
    }

    function _single(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }
}
