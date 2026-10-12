// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Vm} from "forge-std/Test.sol";

import {AgentAttestationRegistry} from "../../src/AgentAttestationRegistry.sol";
import {IAgentAttestationRegistry} from "../../src/interfaces/IAgentAttestationRegistry.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract AgentAttestationRegistryTest is BaseTest {
    uint256 internal constant R =
        21_888_242_871_839_275_222_246_405_745_257_275_088_548_364_400_416_034_343_698_204_186_575_808_495_617;
    uint64 internal constant TTL = 2 hours;

    AgentAttestationRegistry internal registry;
    address internal admin = makeAddr("registry-admin");
    address internal attester = makeAddr("attester");
    address internal nextAttester = makeAddr("next-attester");

    bytes32 internal constant ROOT_1 = bytes32(uint256(0x1111));
    bytes32 internal constant ROOT_2 = bytes32(uint256(0x2222));
    bytes32 internal constant ROOT_3 = bytes32(uint256(0x3333));

    function setUp() public override {
        super.setUp();
        registry = new AgentAttestationRegistry(admin, attester);
    }

    // ------------------------------------------------------------------ helpers

    function _publish(bytes32 root, uint64 epoch) internal {
        vm.prank(attester);
        registry.publishRoot(root, epoch, uint64(block.timestamp) - 60, uint64(block.timestamp) + TTL, 16);
    }

    function _revoke(address by, bytes32 root) internal {
        bytes32[] memory roots = new bytes32[](1);
        roots[0] = root;
        vm.prank(by);
        registry.revokeRoots(roots);
    }

    function _now() internal view returns (uint64) {
        return uint64(block.timestamp);
    }

    // ------------------------------------------------------------------ constructor and constants

    function test_constructor_setsRolesAndEmits() public {
        vm.expectEmit(true, true, false, false);
        emit Ownable.OwnershipTransferred(address(0), admin);
        vm.expectEmit(true, true, false, false);
        emit IAgentAttestationRegistry.AttesterChanged(address(0), attester);
        AgentAttestationRegistry r = new AgentAttestationRegistry(admin, attester);
        assertEq(r.owner(), admin);
        assertEq(r.pendingOwner(), address(0));
        assertEq(r.attester(), attester);
        assertEq(r.latestEpoch(), 0);
        assertEq(r.latestRoot(), bytes32(0));
        assertEq(r.MAX_VALIDITY(), 7 days);
        assertEq(r.SNARK_SCALAR_FIELD(), R);
    }

    /// @dev Deploys through an external call: with dynamic test linking, `vm.expectRevert` + `new` ends the test at
    ///      the first expected revert, silently skipping the rest.
    function deployRegistry(address owner_, address attester_) external returns (AgentAttestationRegistry) {
        return new AgentAttestationRegistry(owner_, attester_);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(IAgentAttestationRegistry.ZeroAddress.selector);
        this.deployRegistry(address(0), attester);
        vm.expectRevert(IAgentAttestationRegistry.ZeroAddress.selector);
        this.deployRegistry(admin, address(0));
        vm.expectRevert(IAgentAttestationRegistry.ZeroAddress.selector);
        this.deployRegistry(address(0), address(0));
        assertEq(this.deployRegistry(admin, admin).attester(), admin, "owner may also be the attester");
    }

    // ------------------------------------------------------------------ publishRoot

    function test_publishRoot_storesAndEmits() public {
        uint64 snapshotAt = _now() - 30;
        uint64 validUntil = _now() + TTL;
        vm.expectEmit(true, true, false, true, address(registry));
        emit IAgentAttestationRegistry.RootPublished(ROOT_1, 7, snapshotAt, validUntil, 1234);
        vm.prank(attester);
        registry.publishRoot(ROOT_1, 7, snapshotAt, validUntil, 1234);

        IAgentAttestationRegistry.RootInfo memory info = registry.rootInfo(ROOT_1);
        assertEq(info.epoch, 7);
        assertEq(info.snapshotAt, snapshotAt);
        assertEq(info.publishedAt, _now());
        assertEq(info.validUntil, validUntil);
        assertEq(info.leafCount, 1234);
        assertFalse(info.revoked);
        assertEq(registry.latestEpoch(), 7);
        assertEq(registry.latestRoot(), ROOT_1);
        assertTrue(registry.isValidRoot(ROOT_1));

        // Epochs may skip; latest* follow the newest root.
        vm.warp(block.timestamp + 1 hours);
        _publish(ROOT_2, 9);
        assertEq(registry.latestEpoch(), 9);
        assertEq(registry.latestRoot(), ROOT_2);
        assertTrue(registry.isValidRoot(ROOT_1), "older roots stay valid until they expire");
    }

    function test_publishRoot_onlyAttester() public {
        address[3] memory callers = [admin, stranger, nextAttester];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.NotAttester.selector, callers[i]));
            registry.publishRoot(ROOT_1, 1, _now(), _now() + TTL, 1);
        }
    }

    function test_publishRoot_rootMustBeANonZeroFieldElement() public {
        bytes32[4] memory bad = [bytes32(0), bytes32(R), bytes32(R + 1), bytes32(type(uint256).max)];
        vm.startPrank(attester);
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.InvalidRoot.selector, bad[i]));
            registry.publishRoot(bad[i], 1, _now(), _now() + TTL, 1);
        }
        registry.publishRoot(bytes32(R - 1), 1, _now(), _now() + TTL, 1);
        registry.publishRoot(bytes32(uint256(1)), 2, _now(), _now() + TTL, 1);
        vm.stopPrank();
    }

    function test_publishRoot_rootCanNeverBeRepublished() public {
        _publish(ROOT_1, 1);
        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.RootAlreadyPublished.selector, ROOT_1));
        registry.publishRoot(ROOT_1, 2, _now(), _now() + TTL, 1);

        // Not after revocation, nor after expiry: a revoked root can never come back.
        _revoke(attester, ROOT_1);
        vm.warp(block.timestamp + 8 days);
        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.RootAlreadyPublished.selector, ROOT_1));
        registry.publishRoot(ROOT_1, 3, _now(), _now() + TTL, 1);
    }

    function test_publishRoot_epochMustIncrease() public {
        vm.startPrank(attester);
        vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.EpochNotIncreasing.selector, 0, 0));
        registry.publishRoot(ROOT_1, 0, _now(), _now() + TTL, 1);
        registry.publishRoot(ROOT_1, 5, _now(), _now() + TTL, 1);
        vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.EpochNotIncreasing.selector, 5, 5));
        registry.publishRoot(ROOT_2, 5, _now(), _now() + TTL, 1);
        vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.EpochNotIncreasing.selector, 5, 4));
        registry.publishRoot(ROOT_2, 4, _now(), _now() + TTL, 1);
        registry.publishRoot(ROOT_2, 6, _now(), _now() + TTL, 1);
        vm.stopPrank();
    }

    function test_publishRoot_snapshotCannotBeInTheFuture() public {
        vm.startPrank(attester);
        vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.SnapshotInFuture.selector, _now() + 1));
        registry.publishRoot(ROOT_1, 1, _now() + 1, _now() + TTL, 1);
        registry.publishRoot(ROOT_1, 1, _now(), _now() + TTL, 1);
        registry.publishRoot(ROOT_2, 2, 0, _now() + TTL, 1);
        vm.stopPrank();
    }

    function test_publishRoot_validityWindowIsMeasuredFromPublication() public {
        uint64[3] memory bad = [_now() - 1, _now(), _now() + 7 days + 1];
        vm.startPrank(attester);
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.InvalidValidity.selector, bad[i]));
            registry.publishRoot(ROOT_1, 1, _now(), bad[i], 1);
        }
        registry.publishRoot(ROOT_1, 1, _now(), _now() + 1, 1);
        registry.publishRoot(ROOT_2, 2, _now(), _now() + 7 days, 1);
        // An old snapshot does not shorten or extend the window: it is relative to block.timestamp.
        registry.publishRoot(ROOT_3, 3, _now() - 30 days, _now() + 7 days, 1);
        vm.stopPrank();
    }

    function test_publishRoot_rejectsEmptyTree() public {
        vm.prank(attester);
        vm.expectRevert(IAgentAttestationRegistry.EmptyTree.selector);
        registry.publishRoot(ROOT_1, 1, _now(), _now() + TTL, 0);
    }

    // ------------------------------------------------------------------ isValidRoot / rootInfo

    function test_isValidRoot_lifecycle() public {
        assertFalse(registry.isValidRoot(ROOT_1), "unknown");
        IAgentAttestationRegistry.RootInfo memory unknown = registry.rootInfo(ROOT_1);
        assertEq(unknown.epoch, 0);
        assertEq(unknown.publishedAt, 0);

        _publish(ROOT_1, 1);
        uint64 validUntil = registry.rootInfo(ROOT_1).validUntil;
        assertTrue(registry.isValidRoot(ROOT_1));
        vm.warp(validUntil);
        assertTrue(registry.isValidRoot(ROOT_1), "valid through validUntil inclusive");
        vm.warp(validUntil + 1);
        assertFalse(registry.isValidRoot(ROOT_1), "expired");

        _publish(ROOT_2, 2);
        _revoke(attester, ROOT_2);
        assertFalse(registry.isValidRoot(ROOT_2), "revoked");
        assertTrue(registry.rootInfo(ROOT_2).revoked);
    }

    // ------------------------------------------------------------------ revokeRoots

    function test_revokeRoots_byAttesterOrOwner_skipsAlreadyRevoked() public {
        _publish(ROOT_1, 1);
        _publish(ROOT_2, 2);
        _publish(ROOT_3, 3);

        vm.expectEmit(true, true, false, true, address(registry));
        emit IAgentAttestationRegistry.RootRevoked(ROOT_1, attester);
        _revoke(attester, ROOT_1);

        bytes32[] memory roots = new bytes32[](3);
        roots[0] = ROOT_1; // already revoked: skipped, no event
        roots[1] = ROOT_2;
        roots[2] = ROOT_2; // duplicate in the same call: skipped
        vm.recordLogs();
        vm.prank(admin);
        registry.revokeRoots(roots);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IAgentAttestationRegistry.RootRevoked.selector);
        assertEq(logs[0].topics[1], ROOT_2);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(admin))));

        assertTrue(registry.rootInfo(ROOT_1).revoked);
        assertTrue(registry.rootInfo(ROOT_2).revoked);
        assertFalse(registry.rootInfo(ROOT_3).revoked);
        assertTrue(registry.isValidRoot(ROOT_3));
        assertEq(registry.latestRoot(), ROOT_3, "revocation does not touch latest*");
    }

    function test_revokeRoots_unknownRootRevertsTheWholeCall() public {
        _publish(ROOT_1, 1);
        bytes32[] memory roots = new bytes32[](2);
        roots[0] = ROOT_1;
        roots[1] = ROOT_2;
        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.UnknownRoot.selector, ROOT_2));
        registry.revokeRoots(roots);
        assertTrue(registry.isValidRoot(ROOT_1));
    }

    function test_revokeRoots_emptyListAndExpiredRoots() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.NotAttesterOrOwner.selector, stranger));
        registry.revokeRoots(new bytes32[](0));
        vm.prank(attester);
        registry.revokeRoots(new bytes32[](0));

        _publish(ROOT_1, 1);
        vm.warp(block.timestamp + 8 days);
        _revoke(admin, ROOT_1);
        assertTrue(registry.rootInfo(ROOT_1).revoked);
    }

    function test_revokeRoots_accessControl() public {
        _publish(ROOT_1, 1);
        address[2] memory callers = [stranger, nextAttester];
        for (uint256 i; i < callers.length; ++i) {
            bytes32[] memory roots = new bytes32[](1);
            roots[0] = ROOT_1;
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.NotAttesterOrOwner.selector, callers[i]));
            registry.revokeRoots(roots);
        }

        // A pending owner has no power until it accepts; a rotated-out attester loses its power at once.
        address nextAdmin = makeAddr("next-admin");
        vm.prank(admin);
        registry.transferOwnership(nextAdmin);
        bytes32[] memory one = new bytes32[](1);
        one[0] = ROOT_1;
        vm.prank(nextAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.NotAttesterOrOwner.selector, nextAdmin));
        registry.revokeRoots(one);
        vm.prank(admin);
        registry.setAttester(nextAttester);
        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.NotAttesterOrOwner.selector, attester));
        registry.revokeRoots(one);
        _revoke(nextAttester, ROOT_1);
        assertFalse(registry.isValidRoot(ROOT_1));
    }

    // ------------------------------------------------------------------ setAttester / ownership

    function test_setAttester_rotatesAndEmits() public {
        vm.expectEmit(true, true, false, false, address(registry));
        emit IAgentAttestationRegistry.AttesterChanged(attester, nextAttester);
        vm.prank(admin);
        registry.setAttester(nextAttester);
        assertEq(registry.attester(), nextAttester);

        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.NotAttester.selector, attester));
        registry.publishRoot(ROOT_1, 1, _now(), _now() + TTL, 1);
        vm.prank(nextAttester);
        registry.publishRoot(ROOT_1, 1, _now(), _now() + TTL, 1);

        // The epoch sequence survives rotation.
        vm.prank(admin);
        registry.setAttester(attester);
        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.EpochNotIncreasing.selector, 1, 1));
        registry.publishRoot(ROOT_2, 1, _now(), _now() + TTL, 1);
    }

    function test_setAttester_reverts() public {
        address[2] memory callers = [attester, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]));
            registry.setAttester(nextAttester);
        }
        vm.prank(admin);
        vm.expectRevert(IAgentAttestationRegistry.ZeroAddress.selector);
        registry.setAttester(address(0));
        assertEq(registry.attester(), attester);
    }

    function test_renounceOwnership_isDisabled() public {
        vm.prank(admin);
        vm.expectRevert(AgentAttestationRegistry.RenounceOwnershipDisabled.selector);
        registry.renounceOwnership();
        vm.prank(stranger);
        vm.expectRevert(AgentAttestationRegistry.RenounceOwnershipDisabled.selector);
        registry.renounceOwnership();
        assertEq(registry.owner(), admin);
    }

    function test_ownership_isTwoStep() public {
        address nextAdmin = makeAddr("next-admin");
        vm.expectEmit(true, true, false, false, address(registry));
        emit Ownable2Step.OwnershipTransferStarted(admin, nextAdmin);
        vm.prank(admin);
        registry.transferOwnership(nextAdmin);
        assertEq(registry.owner(), admin);
        assertEq(registry.pendingOwner(), nextAdmin);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.acceptOwnership();

        vm.prank(nextAdmin);
        registry.acceptOwnership();
        assertEq(registry.owner(), nextAdmin);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        registry.setAttester(nextAttester);
        vm.prank(nextAdmin);
        registry.setAttester(nextAttester);
        assertEq(registry.attester(), nextAttester);
    }

    // ------------------------------------------------------------------ fuzz

    /// @notice Accepted iff block.timestamp < validUntil <= block.timestamp + MAX_VALIDITY, for any clock.
    function testFuzz_publishRoot_validityWindow(uint64 nowTs, uint64 validUntil) public {
        nowTs = uint64(bound(nowTs, 1, type(uint64).max - 8 days));
        vm.warp(nowTs);
        bool ok = validUntil > nowTs && validUntil <= uint256(nowTs) + 7 days;
        vm.prank(attester);
        if (!ok) {
            vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.InvalidValidity.selector, validUntil));
        }
        registry.publishRoot(ROOT_1, 1, nowTs, validUntil, 1);
        assertEq(registry.isValidRoot(ROOT_1), ok);
    }

    /// @notice A root is valid exactly from publication through validUntil, unless revoked.
    function testFuzz_isValidRoot_window(uint64 validFor, uint64 elapsed, bool revoke) public {
        validFor = uint64(bound(validFor, 1, 7 days));
        elapsed = uint64(bound(elapsed, 0, 30 days));
        vm.prank(attester);
        registry.publishRoot(ROOT_1, 1, _now(), _now() + validFor, 1);
        if (revoke) _revoke(admin, ROOT_1);
        vm.warp(block.timestamp + elapsed);
        assertEq(registry.isValidRoot(ROOT_1), !revoke && elapsed <= validFor);
        IAgentAttestationRegistry.RootInfo memory info = registry.rootInfo(ROOT_1);
        assertLe(info.validUntil, info.publishedAt + registry.MAX_VALIDITY());
    }

    /// @notice Epochs strictly increase across any sequence of publish attempts.
    function testFuzz_publishRoot_epochs(uint64 first, uint64 second) public {
        first = uint64(bound(first, 1, type(uint64).max));
        _publish(ROOT_1, first);
        vm.prank(attester);
        if (second <= first) {
            vm.expectRevert(
                abi.encodeWithSelector(IAgentAttestationRegistry.EpochNotIncreasing.selector, first, second)
            );
        }
        registry.publishRoot(ROOT_2, second, _now(), _now() + TTL, 1);
        assertEq(registry.latestEpoch(), second > first ? second : first);
        assertEq(registry.latestRoot(), second > first ? ROOT_2 : ROOT_1);
    }

    /// @notice Only non-zero roots below the BN254 scalar field order are accepted.
    function testFuzz_publishRoot_fieldBound(bytes32 root) public {
        bool ok = root != bytes32(0) && uint256(root) < R;
        vm.prank(attester);
        if (!ok) vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.InvalidRoot.selector, root));
        registry.publishRoot(root, 1, _now(), _now() + TTL, 1);
        assertEq(registry.isValidRoot(root), ok);
    }

    /// @notice Snapshots may be arbitrarily old but never in the future.
    function testFuzz_publishRoot_snapshotAt(uint64 snapshotAt) public {
        vm.prank(attester);
        if (snapshotAt > block.timestamp) {
            vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.SnapshotInFuture.selector, snapshotAt));
        }
        registry.publishRoot(ROOT_1, 1, snapshotAt, _now() + TTL, 1);
    }

    /// @notice Access-control matrix over arbitrary callers.
    function testFuzz_accessControl(address caller) public {
        _publish(ROOT_1, 1);
        bytes32[] memory roots = new bytes32[](1);
        roots[0] = ROOT_1;

        vm.prank(caller);
        if (caller != attester) {
            vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.NotAttester.selector, caller));
        }
        registry.publishRoot(ROOT_2, 2, _now(), _now() + TTL, 1);

        vm.prank(caller);
        if (caller != attester && caller != admin) {
            vm.expectRevert(abi.encodeWithSelector(IAgentAttestationRegistry.NotAttesterOrOwner.selector, caller));
        }
        registry.revokeRoots(roots);

        vm.prank(caller);
        if (caller != admin) {
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        }
        registry.setAttester(nextAttester);
    }
}
