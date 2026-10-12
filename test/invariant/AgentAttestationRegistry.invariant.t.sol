// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AgentAttestationRegistry} from "../../src/AgentAttestationRegistry.sol";
import {IAgentAttestationRegistry} from "../../src/interfaces/IAgentAttestationRegistry.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract RegistryHandler is Test {
    uint256 internal constant R =
        21_888_242_871_839_275_222_246_405_745_257_275_088_548_364_400_416_034_343_698_204_186_575_808_495_617;

    AgentAttestationRegistry public immutable registry;
    address public immutable stranger = makeAddr("inv.stranger");
    address[] public attesters; // candidate attester keys
    address[] public admins; // candidate registry owners

    bytes32[] public roots; // successfully published, in order
    uint64[] public epochs; // their epochs, in order
    mapping(bytes32 root => bool) public ghostRevoked;

    // Postconditions are recorded, not asserted: a failing assert would only revert this handler call.
    uint256 public ghostPublishMismatch; // publish succeeded iff every documented requirement held
    uint256 public ghostUnauthorizedPublish; // a non-attester published
    uint256 public ghostRevokeMismatch; // revoke succeeded iff caller is attester/owner and every root is known
    uint256 public ghostRotateMismatch; // setAttester succeeded iff caller is the owner and the key is non-zero
    uint256 public ghostOwnerRotateFailed; // the owner failed to rotate to a non-zero key
    uint256 public ghostRenounced; // renounceOwnership ever succeeded
    mapping(bytes32 action => uint256) public calls;

    constructor(AgentAttestationRegistry registry_, address[] memory attesters_, address[] memory admins_) {
        registry = registry_;
        attesters = attesters_;
        admins = admins_;
    }

    function publish(
        uint256 actorSeed,
        uint256 rootSeed,
        uint64 epochStep,
        uint64 snapshotAgo,
        uint64 validFor,
        uint32 leafCount
    ) external {
        address caller = _actor(actorSeed);
        bytes32 root = _rootFor(rootSeed);
        uint64 latest = registry.latestEpoch();
        uint64 epoch = latest + uint64(bound(epochStep, 0, 3)); // 0: not increasing
        uint64 nowTs = uint64(block.timestamp);
        uint64 snapshotAt = uint64(bound(snapshotAgo, 0, 2 days));
        snapshotAt = snapshotAt <= 1 days ? nowTs - snapshotAt : nowTs + (snapshotAt - 1 days); // sometimes future
        uint64 validUntil = nowTs + uint64(bound(validFor, 0, 8 days)); // 0 and > 7 days are invalid
        leafCount = uint32(bound(leafCount, 0, 2000));

        bool expected = caller == registry.attester() && root != bytes32(0) && uint256(root) < R
            && registry.rootInfo(root).epoch == 0 && epoch > latest && snapshotAt <= nowTs && validUntil > nowTs
            && validUntil <= nowTs + 7 days && leafCount > 0;

        vm.prank(caller);
        try registry.publishRoot(root, epoch, snapshotAt, validUntil, leafCount) {
            if (!expected) ghostPublishMismatch++;
            if (caller != registry.attester()) ghostUnauthorizedPublish++;
            roots.push(root);
            epochs.push(epoch);
            calls["publish"]++;
        } catch {
            if (expected) ghostPublishMismatch++;
            calls["publish.rejected"]++;
        }
    }

    function revoke(uint256 actorSeed, uint256 rootSeed, uint8 count, bool includeUnknown) external {
        if (roots.length == 0) return;
        address caller = _actor(actorSeed);
        uint256 n = bound(count, 1, 3);
        bytes32[] memory list = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = roots[uint256(keccak256(abi.encode(rootSeed, i))) % roots.length];
        }
        if (includeUnknown) list[n - 1] = keccak256(abi.encode("unknown", rootSeed)) >> 8;

        bool expected = (caller == registry.attester() || caller == registry.owner()) && !includeUnknown;
        vm.prank(caller);
        try registry.revokeRoots(list) {
            if (!expected) ghostRevokeMismatch++;
            for (uint256 i; i < n; ++i) {
                ghostRevoked[list[i]] = true;
            }
            calls["revoke"]++;
        } catch {
            if (expected) ghostRevokeMismatch++;
            calls["revoke.rejected"]++;
        }
    }

    function rotateAttester(uint256 actorSeed, uint256 attesterSeed, bool zero) external {
        address caller = _actor(actorSeed);
        address next = zero ? address(0) : attesters[attesterSeed % attesters.length];
        bool isOwner = caller == registry.owner();
        vm.prank(caller);
        try registry.setAttester(next) {
            if (!isOwner || zero) ghostRotateMismatch++;
            calls["rotate"]++;
        } catch {
            if (isOwner && !zero) {
                ghostRotateMismatch++;
                ghostOwnerRotateFailed++;
            }
            calls["rotate.rejected"]++;
        }
    }

    function transferOwnership(uint256 adminSeed, bool accept) external {
        address next = admins[adminSeed % admins.length];
        vm.prank(registry.owner());
        registry.transferOwnership(next);
        if (accept) {
            vm.prank(next);
            registry.acceptOwnership();
        }
        calls["transferOwnership"]++;
    }

    function renounce(uint256 actorSeed) external {
        vm.prank(_actor(actorSeed));
        try registry.renounceOwnership() {
            ghostRenounced++;
        } catch {
            calls["renounce.rejected"]++;
        }
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 3 days));
        calls["warp"]++;
    }

    function rootsLength() external view returns (uint256) {
        return roots.length;
    }

    /// @dev Mostly the current attester; otherwise the owner, a pending owner, an old attester or a stranger.
    function _actor(uint256 seed) private view returns (address) {
        uint256 pick = seed % 8;
        if (pick < 4) return registry.attester();
        if (pick == 4) return registry.owner();
        if (pick == 5) return admins[(seed >> 8) % admins.length];
        if (pick == 6) return attesters[(seed >> 8) % attesters.length];
        return stranger;
    }

    /// @dev Mostly fresh field elements; sometimes a republished root, zero or a value at or above the field order.
    function _rootFor(uint256 seed) private view returns (bytes32) {
        uint256 pick = seed % 16;
        if (pick == 0) return bytes32(0);
        if (pick == 1) return bytes32(R + (seed >> 8) % 1000);
        if (pick == 2 && roots.length != 0) return roots[(seed >> 8) % roots.length];
        return bytes32(uint256(keccak256(abi.encode(seed))) % R);
    }
}

contract AgentAttestationRegistryInvariantTest is BaseTest {
    AgentAttestationRegistry internal registry;
    RegistryHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory attesters = new address[](3);
        address[] memory admins = new address[](3);
        for (uint256 i; i < 3; ++i) {
            attesters[i] = makeAddr(string.concat("inv.attester", vm.toString(i)));
            admins[i] = makeAddr(string.concat("inv.admin", vm.toString(i)));
        }
        registry = new AgentAttestationRegistry(admins[0], attesters[0]);
        handler = new RegistryHandler(registry, attesters, admins);
        targetContract(address(handler));
    }

    /// @notice Published epochs strictly increase, and latestEpoch/latestRoot track the newest root.
    function invariant_epochsStrictlyIncrease() public view {
        uint256 n = handler.rootsLength();
        for (uint256 i; i < n; ++i) {
            bytes32 root = handler.roots(i);
            assertEq(registry.rootInfo(root).epoch, handler.epochs(i));
            if (i != 0) assertGt(handler.epochs(i), handler.epochs(i - 1));
        }
        assertEq(registry.latestEpoch(), n == 0 ? 0 : handler.epochs(n - 1));
        assertEq(registry.latestRoot(), n == 0 ? bytes32(0) : handler.roots(n - 1));
    }

    /// @notice Only the attester in office publishes; every publish, revoke and rotation succeeded exactly when the
    ///         documented requirements held.
    function invariant_onlyAttesterPublishes() public view {
        assertEq(handler.ghostUnauthorizedPublish(), 0);
        assertEq(handler.ghostPublishMismatch(), 0);
        assertEq(handler.ghostRevokeMismatch(), 0);
        assertEq(handler.ghostRotateMismatch(), 0);
    }

    /// @notice A revoked root is never valid again, and the registry's revoked flags match the ghost exactly.
    function invariant_revokedRootsNeverValid() public view {
        uint256 n = handler.rootsLength();
        for (uint256 i; i < n; ++i) {
            bytes32 root = handler.roots(i);
            bool revoked = handler.ghostRevoked(root);
            assertEq(registry.rootInfo(root).revoked, revoked);
            if (revoked) assertFalse(registry.isValidRoot(root));
        }
    }

    /// @notice Every root's window is (publishedAt, publishedAt + MAX_VALIDITY], its snapshot is no later than its
    ///         publication, its tree is non-empty, and it is valid exactly while unrevoked and unexpired.
    function invariant_validRootsWithinMaxValidity() public view {
        uint256 n = handler.rootsLength();
        uint64 maxValidity = registry.MAX_VALIDITY();
        for (uint256 i; i < n; ++i) {
            bytes32 root = handler.roots(i);
            IAgentAttestationRegistry.RootInfo memory info = registry.rootInfo(root);
            assertLe(info.validUntil, info.publishedAt + maxValidity);
            assertGt(info.validUntil, info.publishedAt);
            assertLe(info.snapshotAt, info.publishedAt);
            assertGt(info.leafCount, 0);
            assertEq(registry.isValidRoot(root), !info.revoked && block.timestamp <= info.validUntil);
        }
    }

    /// @notice The registry always has an owner, and that owner can always rotate the attester.
    function invariant_ownerCanAlwaysRotateAttester() public {
        assertEq(handler.ghostRenounced(), 0);
        assertEq(handler.ghostOwnerRotateFailed(), 0);
        address owner = registry.owner();
        assertTrue(owner != address(0));
        uint256 snapshot = vm.snapshotState();
        address fresh = makeAddr("inv.fresh-attester");
        vm.prank(owner);
        registry.setAttester(fresh);
        assertEq(registry.attester(), fresh);
        vm.revertToState(snapshot);
    }
}
