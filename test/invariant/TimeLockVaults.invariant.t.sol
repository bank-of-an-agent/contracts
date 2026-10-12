// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";

import {TimeLockVaults} from "../../src/TimeLockVaults.sol";
import {ITimeLockVaults} from "../../src/interfaces/ITimeLockVaults.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract VaultsHandler is Test {
    TimeLockVaults public immutable vaults;
    MockUSDC public immutable usdc;
    address public immutable relayer = makeAddr("inv.relayer");

    address[] public accounts; // parent smart accounts: the only legitimate destinations
    address[] public depositors;
    Vm.Wallet[] internal owners;
    uint256[] public ids;
    mapping(address owner => uint256) internal ownerIndexPlusOne;

    uint256 public ghostMinted;
    uint256 public ghostDonated;
    uint256 public ghostUnsignedEarlyWithdrawals; // must stay 0
    mapping(uint256 id => uint256) public ghostDeposited;
    mapping(uint256 id => uint256) public ghostWithdrawn;
    mapping(bytes32 action => uint256) public calls;

    constructor(TimeLockVaults vaults_, MockUSDC usdc_) {
        vaults = vaults_;
        usdc = usdc_;
        for (uint256 i; i < 3; ++i) {
            accounts.push(makeAddr(string.concat("inv.account", vm.toString(i))));
            Vm.Wallet memory w = vm.createWallet(string.concat("inv.owner", vm.toString(i)));
            owners.push(w);
            ownerIndexPlusOne[w.addr] = i + 1;
        }
        for (uint256 i; i < 2; ++i) {
            depositors.push(makeAddr(string.concat("inv.depositor", vm.toString(i))));
        }
    }

    function create(uint256 accountSeed, uint256 ownerSeed, uint256 lockFor) external {
        address account = accounts[accountSeed % accounts.length];
        address owner = owners[ownerSeed % owners.length].addr;
        vm.prank(account);
        uint256 id = vaults.createVault(address(usdc), uint64(block.timestamp + bound(lockFor, 1, 120 days)), owner);
        ids.push(id);
        calls["create"]++;
    }

    function deposit(uint256 idSeed, uint256 depositorSeed, uint256 amount) external {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        address from = depositors[depositorSeed % depositors.length];
        amount = bound(amount, 1, 1e15);
        usdc.mint(from, amount);
        ghostMinted += amount;
        vm.startPrank(from);
        usdc.approve(address(vaults), amount);
        vaults.deposit(id, amount);
        vm.stopPrank();
        ghostDeposited[id] += amount;
        calls["deposit"]++;
    }

    function withdraw(uint256 idSeed, uint256 amount) external {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        ITimeLockVaults.Vault memory v = vaults.getVault(id);
        if (v.balance == 0) return;
        amount = bound(amount, 1, v.balance);
        vm.prank(relayer);
        try vaults.withdraw(id, amount) {
            if (block.timestamp < v.unlockAt) ghostUnsignedEarlyWithdrawals++;
            ghostWithdrawn[id] += amount;
            calls["withdraw"]++;
        } catch {
            calls["withdraw.locked"]++;
        }
    }

    function withdrawSigned(uint256 idSeed, uint256 amount, bool byOwner) external {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        ITimeLockVaults.Vault memory v = vaults.getVault(id);
        if (v.balance == 0) return;
        amount = bound(amount, 1, v.balance);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 pk = _keyFor(v.owner, byOwner);
        bytes32 digest = vaults.earlyWithdrawalDigest(id, amount, v.nonce, deadline);
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        vm.prank(relayer);
        try vaults.withdrawWithSignature(id, amount, deadline, abi.encodePacked(r, s, sv)) {
            assertTrue(byOwner, "a non-owner signature withdrew funds");
            ghostWithdrawn[id] += amount;
            calls["withdrawSigned"]++;
        } catch {
            assertFalse(byOwner, "the owner's signature was rejected");
            calls["withdrawSigned.rejected"]++;
        }
    }

    function rotateOwner(uint256 idSeed, uint256 newOwnerSeed) external {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        ITimeLockVaults.Vault memory v = vaults.getVault(id);
        address newOwner = owners[newOwnerSeed % owners.length].addr;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = vaults.setOwnerDigest(id, newOwner, v.nonce, deadline);
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(_keyFor(v.owner, true), digest);
        vaults.setOwner(id, newOwner, deadline, abi.encodePacked(r, s, sv));
        calls["rotateOwner"]++;
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 20 days));
        calls["warp"]++;
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1e12);
        usdc.mint(address(vaults), amount);
        ghostMinted += amount;
        ghostDonated += amount;
        calls["donate"]++;
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function accountsLength() external view returns (uint256) {
        return accounts.length;
    }

    function depositorsLength() external view returns (uint256) {
        return depositors.length;
    }

    function ownerAddress(uint256 i) external view returns (address) {
        return owners[i].addr;
    }

    function _pick(uint256 seed) private view returns (uint256) {
        if (ids.length == 0) return 0;
        return ids[seed % ids.length];
    }

    /// @dev The owner's key, or (if !owner) a different owner's key, i.e. a valid but unauthorised signer.
    function _keyFor(address owner, bool useOwner) private view returns (uint256) {
        uint256 i = ownerIndexPlusOne[owner] - 1;
        return useOwner ? owners[i].privateKey : owners[(i + 1) % owners.length].privateKey;
    }
}

contract TimeLockVaultsInvariantTest is BaseTest {
    TimeLockVaults internal vaults;
    VaultsHandler internal handler;

    function setUp() public override {
        super.setUp();
        vaults = new TimeLockVaults(guardian);
        handler = new VaultsHandler(vaults, usdc);
        targetContract(address(handler));
    }

    /// @notice Holdings equal the sum of vault balances (plus donations), and each vault's balance equals what went
    ///         in minus what came out.
    function invariant_accounting() public view {
        uint256 sum;
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            uint256 balance = vaults.getVault(id).balance;
            assertEq(balance, handler.ghostDeposited(id) - handler.ghostWithdrawn(id));
            sum += balance;
        }
        assertEq(vaults.totalHeld(address(usdc)), sum);
        assertEq(usdc.balanceOf(address(vaults)), sum + handler.ghostDonated());
    }

    /// @notice Withdrawals only ever reach parent accounts; owners, relayers and depositors never receive vault funds.
    function invariant_fundsOnlyReturnToParentAccounts() public view {
        uint256 toAccounts;
        for (uint256 i; i < handler.accountsLength(); ++i) {
            toAccounts += usdc.balanceOf(handler.accounts(i));
        }
        uint256 withdrawn;
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; ++i) {
            withdrawn += handler.ghostWithdrawn(handler.ids(i));
        }
        assertEq(toAccounts, withdrawn);
        for (uint256 i; i < 3; ++i) {
            assertEq(usdc.balanceOf(handler.ownerAddress(i)), 0);
        }
        assertEq(usdc.balanceOf(handler.relayer()), 0);
        uint256 held = usdc.balanceOf(address(vaults)) + toAccounts;
        for (uint256 i; i < handler.depositorsLength(); ++i) {
            held += usdc.balanceOf(handler.depositors(i));
        }
        assertEq(held, handler.ghostMinted());
    }

    /// @notice Nothing ever left a vault before its unlock time without the owner's signature.
    function invariant_noUnsignedEarlyWithdrawal() public view {
        assertEq(handler.ghostUnsignedEarlyWithdrawals(), 0);
    }
}
