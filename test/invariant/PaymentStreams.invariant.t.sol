// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {PaymentStreams} from "../../src/PaymentStreams.sol";
import {IPaymentStreams} from "../../src/interfaces/IPaymentStreams.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract StreamsHandler is Test {
    PaymentStreams public immutable streams;
    MockUSDC public immutable usdc;
    address public immutable outsider = makeAddr("inv.outsider");

    address[] public actors;
    uint256[] public ids;

    uint256 public ghostMinted;
    uint256 public ghostDonated;
    mapping(uint256 id => uint256) public ghostAccruedAtCancel;
    uint256 public ghostUnauthorizedCancels; // must stay 0
    uint256 public ghostForeignTopUps; // must stay 0
    mapping(bytes32 action => uint256) public calls;

    constructor(PaymentStreams streams_, MockUSDC usdc_) {
        streams = streams_;
        usdc = usdc_;
        for (uint256 i; i < 4; ++i) {
            actors.push(makeAddr(string.concat("inv.actor", vm.toString(i))));
        }
    }

    function create(
        uint256 payerSeed,
        uint256 payeeSeed,
        uint256 deposit,
        uint256 rate,
        uint256 interval,
        uint256 startDelay,
        uint256 duration
    ) external {
        uint256 n = actors.length;
        address p = actors[payerSeed % n];
        address q = actors[(payerSeed % n + 1 + payeeSeed % (n - 1)) % n];
        if (usdc.isBlacklisted(p)) return;
        deposit = bound(deposit, 1, 1e15);
        rate = bound(rate, 1, 1e12);
        interval = bound(interval, 1, 7 days);
        uint64 start = uint64(block.timestamp + bound(startDelay, 0, 3 days));
        duration = bound(duration, 0, 60 days);
        uint64 stop = duration == 0 ? 0 : start + uint64(duration);

        usdc.mint(p, deposit);
        ghostMinted += deposit;
        vm.startPrank(p);
        usdc.approve(address(streams), deposit);
        uint256 id = streams.createStream(address(usdc), q, deposit, rate, uint64(interval), start, stop);
        vm.stopPrank();
        ids.push(id);
        calls["create"]++;
    }

    function topUp(uint256 idSeed, uint256 amount) external {
        (uint256 id, IPaymentStreams.Stream memory s) = _pick(idSeed);
        if (id == 0 || usdc.isBlacklisted(s.payer)) return;
        amount = bound(amount, 1, 1e15);
        usdc.mint(s.payer, amount);
        ghostMinted += amount;
        vm.startPrank(s.payer);
        usdc.approve(address(streams), amount);
        try streams.topUp(id, amount) {
            calls["topUp"]++;
        } catch {
            calls["topUp.reverted"]++; // canceled or past stop
        }
        vm.stopPrank();
    }

    /// @dev An outsider tries to fund someone else's stream (e.g. an agent tricked into it): must always fail.
    function foreignTopUp(uint256 idSeed, uint256 amount) external {
        (uint256 id,) = _pick(idSeed);
        if (id == 0) return;
        amount = bound(amount, 1, 1e12);
        usdc.mint(outsider, amount);
        ghostMinted += amount;
        vm.startPrank(outsider);
        usdc.approve(address(streams), amount);
        try streams.topUp(id, amount) {
            ghostForeignTopUps++;
        } catch {}
        vm.stopPrank();
    }

    function settle(uint256 idSeed) external {
        (uint256 id,) = _pick(idSeed);
        if (id == 0) return;
        vm.prank(outsider);
        try streams.settle(id) {
            calls["settle"]++;
        } catch {
            calls["settle.reverted"]++; // payee frozen
        }
    }

    function cancel(uint256 idSeed, bool byPayee) external {
        (uint256 id, IPaymentStreams.Stream memory s) = _pick(idSeed);
        if (id == 0) return;
        uint256 accruedNow = streams.accrued(id);
        vm.prank(byPayee ? s.payee : s.payer);
        try streams.cancel(id) {
            if (byPayee) ghostUnauthorizedCancels++;
            ghostAccruedAtCancel[id] = accruedNow;
            calls["cancel"]++;
        } catch {
            calls["cancel.reverted"]++; // already canceled or payer frozen
        }
    }

    function toggleFreeze(uint256 actorSeed) external {
        address a = actors[actorSeed % actors.length];
        bool frozen = usdc.isBlacklisted(a);
        vm.prank(usdc.blacklister());
        if (frozen) usdc.unBlacklist(a);
        else usdc.blacklist(a);
        calls["toggleFreeze"]++;
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 10 days));
        calls["warp"]++;
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1e12);
        usdc.mint(address(streams), amount);
        ghostMinted += amount;
        ghostDonated += amount;
        calls["donate"]++;
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function _pick(uint256 seed) private view returns (uint256 id, IPaymentStreams.Stream memory s) {
        if (ids.length == 0) return (0, s);
        id = ids[seed % ids.length];
        s = streams.getStream(id);
    }
}

contract PaymentStreamsInvariantTest is BaseTest {
    PaymentStreams internal streams;
    StreamsHandler internal handler;

    function setUp() public override {
        super.setUp();
        streams = new PaymentStreams(guardian);
        handler = new StreamsHandler(streams, usdc);
        targetContract(address(handler));
    }

    /// @notice Per stream: paid + refunded <= deposit, paid <= accrued <= deposit, and canceled streams are frozen
    ///         with refunded == deposit - accruedAtCancel.
    function invariant_perStreamAccounting() public view {
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            IPaymentStreams.Stream memory s = streams.getStream(id);
            uint256 accruedNow = streams.accrued(id);
            assertLe(uint256(s.paid) + s.refunded, s.deposit, "paid + refunded <= deposit");
            assertLe(s.paid, accruedNow, "paid <= accrued");
            assertLe(accruedNow, s.deposit, "accrued <= deposit");
            if (s.canceled) {
                assertEq(accruedNow, handler.ghostAccruedAtCancel(id), "accrual frozen after cancel");
                assertEq(s.refunded, uint256(s.deposit) - accruedNow, "refund = deposit - accrued");
            } else {
                assertEq(s.refunded, 0);
            }
        }
    }

    /// @notice The contract balance equals the sum of outstanding amounts (plus unsolicited donations).
    function invariant_balanceEqualsSumOfOutstanding() public view {
        uint256 sum;
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; ++i) {
            sum += streams.outstanding(handler.ids(i));
        }
        assertEq(streams.totalOutstanding(address(usdc)), sum);
        assertEq(usdc.balanceOf(address(streams)), sum + handler.ghostDonated());
    }

    /// @notice Tokens only move between stream parties and the contract (an outsider's failed top-ups stay with it).
    function invariant_conservation() public view {
        uint256 held = usdc.balanceOf(address(streams)) + usdc.balanceOf(handler.outsider());
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; ++i) {
            held += usdc.balanceOf(handler.actors(i));
        }
        assertEq(held, handler.ghostMinted());
    }

    /// @notice Only the payer ever cancels or tops up a stream.
    function invariant_onlyPayerCancelsOrTopsUp() public view {
        assertEq(handler.ghostUnauthorizedCancels(), 0);
        assertEq(handler.ghostForeignTopUps(), 0);
    }
}
