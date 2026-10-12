// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AgentEscrow} from "../../src/AgentEscrow.sol";
import {IAgentEscrow} from "../../src/interfaces/IAgentEscrow.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockValidationRegistry} from "../../src/mocks/MockValidationRegistry.sol";
import {BaseTest} from "../utils/BaseTest.sol";

/// @notice Drives AgentEscrow with random but well-formed actions and keeps ghost accounting.
contract EscrowHandler is Test {
    AgentEscrow public immutable escrow;
    MockUSDC public immutable usdc;
    MockValidationRegistry public immutable registry;
    address public immutable arbiter = makeAddr("inv.arbiter");
    address public immutable validator = makeAddr("inv.validator");
    address public immutable outsider = makeAddr("inv.outsider");

    address[] public actors;
    uint256[] public ids;

    mapping(uint256 id => uint256) public ghostPaidOut;
    mapping(uint256 id => IAgentEscrow.Status) public ghostStatus;
    mapping(bytes32 requestHash => bool) public requested;
    uint256 public ghostMinted;
    uint256 public ghostDonated;
    uint256 public ghostOpenAmount;
    mapping(bytes32 action => uint256) public calls;

    constructor(AgentEscrow escrow_, MockUSDC usdc_, MockValidationRegistry registry_) {
        escrow = escrow_;
        usdc = usdc_;
        registry = registry_;
        for (uint256 i; i < 4; ++i) {
            actors.push(makeAddr(string.concat("inv.actor", vm.toString(i))));
        }
    }

    // ------------------------------------------------------------------ actions

    function lock(
        uint256 payerSeed,
        uint256 payeeSeed,
        uint256 amount,
        uint256 duration,
        bool withArbiter,
        bool withValidator,
        uint256 threshold
    ) external {
        uint256 n = actors.length;
        address p = actors[payerSeed % n];
        address q = actors[(payerSeed % n + 1 + payeeSeed % (n - 1)) % n]; // always != p
        amount = bound(amount, 1, 1e15);
        duration = bound(duration, 1, 365 days);
        uint256 id = escrow.escrowCount() + 1;
        address v = withValidator ? validator : address(0);
        bytes32 requestHash = withValidator ? keccak256(abi.encode("inv.request", id)) : bytes32(0);
        uint8 t = withValidator ? uint8(bound(threshold, 1, 100)) : 0;

        usdc.mint(p, amount);
        ghostMinted += amount;
        vm.startPrank(p);
        usdc.approve(address(escrow), amount);
        escrow.lock(
            address(usdc),
            q,
            amount,
            uint64(block.timestamp + duration),
            withArbiter ? arbiter : address(0),
            v,
            requestHash,
            t,
            keccak256(abi.encode(id))
        );
        vm.stopPrank();

        ids.push(id);
        ghostStatus[id] = IAgentEscrow.Status.Active;
        ghostOpenAmount += amount;
        calls["lock"]++;
    }

    function release(uint256 idSeed, bool byArbiter) external {
        (uint256 id, IAgentEscrow.Escrow memory e) = _pick(idSeed);
        if (id == 0) return;
        address caller = byArbiter && e.arbiter != address(0) ? e.arbiter : e.payer;
        vm.prank(caller);
        try escrow.release(id) {
            _closed(id, IAgentEscrow.Status.Released);
            calls["release"]++;
        } catch {
            calls["release.reverted"]++;
        }
    }

    function refund(uint256 idSeed, uint256 callerSeed) external {
        (uint256 id, IAgentEscrow.Escrow memory e) = _pick(idSeed);
        if (id == 0) return;
        address[3] memory callers = [e.payee, e.payer, outsider];
        vm.prank(callers[callerSeed % 3]);
        try escrow.refund(id) {
            _closed(id, IAgentEscrow.Status.Refunded);
            calls["refund"]++;
        } catch {
            calls["refund.reverted"]++;
        }
    }

    function dispute(uint256 idSeed, bool byPayee) external {
        (uint256 id, IAgentEscrow.Escrow memory e) = _pick(idSeed);
        if (id == 0) return;
        vm.prank(byPayee ? e.payee : e.payer);
        try escrow.dispute(id) {
            ghostStatus[id] = IAgentEscrow.Status.Disputed;
            calls["dispute"]++;
        } catch {
            calls["dispute.reverted"]++;
        }
    }

    function resolve(uint256 idSeed, uint256 split) external {
        (uint256 id, IAgentEscrow.Escrow memory e) = _pick(idSeed);
        if (id == 0 || e.arbiter == address(0)) return;
        vm.prank(e.arbiter);
        try escrow.resolve(id, bound(split, 0, e.amount)) {
            _closed(id, IAgentEscrow.Status.Resolved);
            calls["resolve"]++;
        } catch {
            calls["resolve.reverted"]++;
        }
    }

    function respond(uint256 idSeed, uint256 response) external {
        (uint256 id, IAgentEscrow.Escrow memory e) = _pick(idSeed);
        if (id == 0 || e.validator == address(0)) return;
        if (!requested[e.validationRequestHash]) {
            registry.validationRequest(e.validator, id, "ipfs://inv", e.validationRequestHash);
            requested[e.validationRequestHash] = true;
        }
        vm.prank(e.validator);
        registry.validationResponse(e.validationRequestHash, uint8(bound(response, 0, 100)), "", bytes32(0), "");
        calls["respond"]++;
    }

    function releaseByValidation(uint256 idSeed) external {
        (uint256 id,) = _pick(idSeed);
        if (id == 0) return;
        vm.prank(outsider);
        try escrow.releaseByValidation(id) {
            _closed(id, IAgentEscrow.Status.Released);
            calls["releaseByValidation"]++;
        } catch {
            calls["releaseByValidation.reverted"]++;
        }
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 45 days));
        calls["warp"]++;
    }

    /// @dev Unsolicited transfers to the escrow must never be mistaken for liabilities (or become withdrawable).
    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1e12);
        usdc.mint(address(escrow), amount);
        ghostMinted += amount;
        ghostDonated += amount;
        calls["donate"]++;
    }

    // ------------------------------------------------------------------ helpers for the invariant contract

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function _pick(uint256 seed) private view returns (uint256 id, IAgentEscrow.Escrow memory e) {
        if (ids.length == 0) return (0, e);
        id = ids[seed % ids.length];
        e = escrow.getEscrow(id);
    }

    function _closed(uint256 id, IAgentEscrow.Status status) private {
        uint256 amount = escrow.getEscrow(id).amount;
        ghostPaidOut[id] += amount;
        ghostOpenAmount -= amount;
        ghostStatus[id] = status;
    }
}

contract AgentEscrowInvariantTest is BaseTest {
    AgentEscrow internal escrow;
    MockValidationRegistry internal registry;
    EscrowHandler internal handler;

    function setUp() public override {
        super.setUp();
        registry = new MockValidationRegistry();
        escrow = new AgentEscrow(guardian, address(registry));
        handler = new EscrowHandler(escrow, usdc, registry);
        targetContract(address(handler));
    }

    /// @notice The escrow always holds at least its liabilities; exactly liabilities plus donations.
    function invariant_balanceCoversLockedFunds() public view {
        uint256 locked = escrow.totalLocked(address(usdc));
        assertGe(usdc.balanceOf(address(escrow)), locked);
        assertEq(usdc.balanceOf(address(escrow)), locked + handler.ghostDonated());
    }

    /// @notice `totalLocked` equals the sum of Active and Disputed escrow amounts.
    function invariant_totalLockedMatchesOpenEscrows() public view {
        uint256 open;
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; ++i) {
            IAgentEscrow.Escrow memory e = escrow.getEscrow(handler.ids(i));
            if (e.status == IAgentEscrow.Status.Active || e.status == IAgentEscrow.Status.Disputed) open += e.amount;
        }
        assertEq(escrow.totalLocked(address(usdc)), open);
        assertEq(open, handler.ghostOpenAmount());
    }

    /// @notice Every escrow pays out exactly once, and only after reaching a terminal status that never changes.
    function invariant_paidOutExactlyOnceAndTerminalIsFinal() public view {
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            IAgentEscrow.Escrow memory e = escrow.getEscrow(id);
            assertEq(uint8(e.status), uint8(handler.ghostStatus(id)), "status drift");
            bool terminal = e.status == IAgentEscrow.Status.Released || e.status == IAgentEscrow.Status.Refunded
                || e.status == IAgentEscrow.Status.Resolved;
            assertEq(handler.ghostPaidOut(id), terminal ? e.amount : 0, "payout mismatch");
        }
    }

    /// @notice Funds only ever flow between payers, payees and the escrow: no third party gains anything.
    function invariant_conservationAndNoLeakage() public view {
        uint256 held = usdc.balanceOf(address(escrow));
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; ++i) {
            held += usdc.balanceOf(handler.actors(i));
        }
        assertEq(held, handler.ghostMinted());
        assertEq(usdc.balanceOf(handler.arbiter()), 0);
        assertEq(usdc.balanceOf(handler.validator()), 0);
        assertEq(usdc.balanceOf(handler.outsider()), 0);
    }

    function afterInvariant() external view {
        // Sanity: the campaign actually exercised the state machine.
        assertGt(handler.calls("lock") + handler.calls("warp") + handler.calls("donate"), 0);
    }
}
