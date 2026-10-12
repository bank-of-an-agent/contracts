// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {GuardianPausable} from "../../src/utils/GuardianPausable.sol";

/// @notice Minimal consumer: one inflow (pausable) and one exit (never pausable).
contract PausableHarness is GuardianPausable {
    uint256 public deposits;
    uint256 public exits;

    constructor(address guardian_) GuardianPausable(guardian_) {}

    function deposit() external whenNotPaused {
        deposits++;
    }

    function exit() external {
        exits++;
    }
}

contract GuardianPausableTest is Test {
    PausableHarness internal harness;
    address internal guardian = makeAddr("guardian");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        harness = new PausableHarness(guardian);
    }

    function test_constructor_emitsAndSets() public {
        vm.expectEmit(true, true, false, false);
        emit GuardianPausable.PauseGuardianTransferred(address(0), guardian);
        PausableHarness h = new PausableHarness(guardian);
        assertEq(h.pauseGuardian(), guardian);
        assertFalse(h.paused());
    }

    function test_pause_blocksDepositsOnly() public {
        vm.expectEmit(true, false, false, false, address(harness));
        emit GuardianPausable.Paused(guardian);
        vm.prank(guardian);
        harness.pause();
        assertTrue(harness.paused());

        vm.expectRevert(GuardianPausable.NewDepositsPaused.selector);
        harness.deposit();
        harness.exit();
        assertEq(harness.exits(), 1);

        vm.expectEmit(true, false, false, false, address(harness));
        emit GuardianPausable.Unpaused(guardian);
        vm.prank(guardian);
        harness.unpause();
        harness.deposit();
        assertEq(harness.deposits(), 1);
    }

    function test_pause_stateMustChange() public {
        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(GuardianPausable.PauseStateUnchanged.selector, false));
        harness.unpause();
        harness.pause();
        vm.expectRevert(abi.encodeWithSelector(GuardianPausable.PauseStateUnchanged.selector, true));
        harness.pause();
        vm.stopPrank();
    }

    function test_onlyGuardian() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(GuardianPausable.NotPauseGuardian.selector, stranger));
        harness.pause();
        vm.expectRevert(abi.encodeWithSelector(GuardianPausable.NotPauseGuardian.selector, stranger));
        harness.unpause();
        vm.expectRevert(abi.encodeWithSelector(GuardianPausable.NotPauseGuardian.selector, stranger));
        harness.transferPauseGuardian(stranger);
        vm.stopPrank();
    }

    function test_transferAndRenounce() public {
        vm.expectEmit(true, true, false, false, address(harness));
        emit GuardianPausable.PauseGuardianTransferred(guardian, stranger);
        vm.prank(guardian);
        harness.transferPauseGuardian(stranger);
        assertEq(harness.pauseGuardian(), stranger);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(GuardianPausable.NotPauseGuardian.selector, guardian));
        harness.pause();

        // pause, then renounce: the contract is retired for deposits forever, exits keep working
        vm.startPrank(stranger);
        harness.pause();
        harness.transferPauseGuardian(address(0));
        vm.stopPrank();
        assertEq(harness.pauseGuardian(), address(0));
        vm.expectRevert(GuardianPausable.NewDepositsPaused.selector);
        harness.deposit();
        harness.exit();
    }

    function test_noGuardian_neverPausable() public {
        PausableHarness h = new PausableHarness(address(0));
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(GuardianPausable.NotPauseGuardian.selector, address(0)));
        h.pause();
    }

    function testFuzz_onlyGuardianCanToggle(address caller) public {
        vm.assume(caller != guardian);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(GuardianPausable.NotPauseGuardian.selector, caller));
        harness.pause();
        assertFalse(harness.paused());
    }
}

contract PausableHandler is Test {
    PausableHarness public immutable harness;
    address[] public actors;
    uint256 public ghostExitAttempts;
    uint256 public ghostExitFailures; // must stay 0
    uint256 public ghostUnauthorizedToggles; // must stay 0

    constructor(PausableHarness harness_, address guardian) {
        harness = harness_;
        actors.push(guardian);
        actors.push(makeAddr("inv.stranger"));
        actors.push(makeAddr("inv.next-guardian"));
    }

    function toggle(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        bool wasGuardian = actor == harness.pauseGuardian();
        bool wasPaused = harness.paused();
        vm.prank(actor);
        if (wasPaused) {
            try harness.unpause() {
                if (!wasGuardian) ghostUnauthorizedToggles++;
            } catch {}
        } else {
            try harness.pause() {
                if (!wasGuardian) ghostUnauthorizedToggles++;
            } catch {}
        }
    }

    function transfer(uint256 actorSeed, uint256 toSeed) external {
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        try harness.transferPauseGuardian(actors[toSeed % actors.length]) {} catch {}
    }

    function deposit() external {
        try harness.deposit() {} catch {}
    }

    function exit() external {
        ghostExitAttempts++;
        try harness.exit() {}
        catch {
            ghostExitFailures++;
        }
    }
}

contract GuardianPausableInvariantTest is Test {
    PausableHarness internal harness;
    PausableHandler internal handler;

    function setUp() public {
        harness = new PausableHarness(makeAddr("guardian"));
        handler = new PausableHandler(harness, makeAddr("guardian"));
        targetContract(address(handler));
    }

    /// @notice Exits always work, and only the guardian of the moment can change the pause state.
    function invariant_exitsNeverBlocked_onlyGuardianToggles() public view {
        assertEq(handler.ghostExitFailures(), 0);
        assertEq(handler.ghostUnauthorizedToggles(), 0);
        assertEq(harness.exits(), handler.ghostExitAttempts());
    }
}
