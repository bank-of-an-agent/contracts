// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {PaymentStreams} from "../../src/PaymentStreams.sol";
import {IPaymentStreams} from "../../src/interfaces/IPaymentStreams.sol";
import {GuardianPausable} from "../../src/utils/GuardianPausable.sol";
import {TokenTransfer} from "../../src/utils/TokenTransfer.sol";
import {CallbackToken, FeeOnTransferToken} from "../mocks/TestTokens.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract PaymentStreamsTest is BaseTest {
    PaymentStreams internal streams;

    uint256 internal constant RATE = 1000; // 0.001 USDC per second
    uint256 internal constant DEPOSIT = 3600 * RATE; // one hour of streaming

    function setUp() public override {
        super.setUp();
        streams = new PaymentStreams(guardian);
        _fundAndApprove(payer, address(streams), 1_000_000_000 * USDC_UNIT);
    }

    // ------------------------------------------------------------------ helpers

    function _perSecond() internal returns (uint256 id) {
        vm.prank(payer);
        id = streams.createStream(address(usdc), payee, DEPOSIT, RATE, 1, 0, 0);
    }

    function _monthly(uint256 months, uint64 stop) internal returns (uint256 id) {
        vm.prank(payer);
        id = streams.createStream(address(usdc), payee, months * 10 * USDC_UNIT, 10 * USDC_UNIT, 30 days, 0, stop);
    }

    // ------------------------------------------------------------------ create

    function test_create_storesStreamPullsDepositAndEmits() public {
        vm.expectEmit(true, true, true, true, address(streams));
        emit IPaymentStreams.StreamCreated(1, payer, payee, address(usdc), DEPOSIT, RATE, 1, uint64(block.timestamp), 0);
        uint256 id = _perSecond();
        assertEq(id, 1);
        assertEq(streams.streamCount(), 1);

        IPaymentStreams.Stream memory s = streams.getStream(id);
        assertEq(s.payer, payer);
        assertEq(s.payee, payee);
        assertEq(s.token, address(usdc));
        assertEq(s.start, block.timestamp);
        assertEq(s.stop, 0);
        assertEq(s.interval, 1);
        assertEq(s.amountPerInterval, RATE);
        assertEq(s.deposit, DEPOSIT);
        assertEq(s.paid, 0);
        assertEq(s.refunded, 0);
        assertFalse(s.canceled);
        assertEq(usdc.balanceOf(address(streams)), DEPOSIT);
        assertEq(streams.totalOutstanding(address(usdc)), DEPOSIT);
        assertEq(streams.outstanding(id), DEPOSIT);
    }

    function test_create_futureStartAndStop() public {
        uint64 start = uint64(block.timestamp + 1 days);
        vm.prank(payer);
        uint256 id = streams.createStream(address(usdc), payee, DEPOSIT, RATE, 1, start, start + 100);
        assertEq(streams.getStream(id).start, start);
        assertEq(streams.getStream(id).stop, start + 100);
        assertEq(streams.accrued(id), 0);
    }

    function test_create_revertsOnInvalidParams() public {
        vm.startPrank(payer);
        vm.expectRevert(IPaymentStreams.ZeroAddress.selector);
        streams.createStream(address(0), payee, DEPOSIT, RATE, 1, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.InvalidPayee.selector, address(0)));
        streams.createStream(address(usdc), address(0), DEPOSIT, RATE, 1, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.InvalidPayee.selector, payer));
        streams.createStream(address(usdc), payer, DEPOSIT, RATE, 1, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.InvalidPayee.selector, address(streams)));
        streams.createStream(address(usdc), address(streams), DEPOSIT, RATE, 1, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.InvalidAmount.selector, 0));
        streams.createStream(address(usdc), payee, 0, RATE, 1, 0, 0);
        uint256 tooBig = uint256(type(uint128).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.InvalidAmount.selector, tooBig));
        streams.createStream(address(usdc), payee, tooBig, RATE, 1, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.InvalidRate.selector, 0));
        streams.createStream(address(usdc), payee, DEPOSIT, 0, 1, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.InvalidRate.selector, tooBig));
        streams.createStream(address(usdc), payee, DEPOSIT, tooBig, 1, 0, 0);
        vm.expectRevert(IPaymentStreams.InvalidInterval.selector);
        streams.createStream(address(usdc), payee, DEPOSIT, RATE, 0, 0, 0);
        uint64 past = uint64(block.timestamp - 1);
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.InvalidStart.selector, past));
        streams.createStream(address(usdc), payee, DEPOSIT, RATE, 1, past, 0);
        uint64 nowTs = uint64(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.InvalidStop.selector, nowTs));
        streams.createStream(address(usdc), payee, DEPOSIT, RATE, 1, 0, nowTs);
        vm.stopPrank();
    }

    function test_create_rejectsFeeOnTransferToken() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(payer, 10_000);
        vm.startPrank(payer);
        fot.approve(address(streams), 10_000);
        vm.expectRevert(
            abi.encodeWithSelector(TokenTransfer.TransferAmountMismatch.selector, address(fot), 10_000, 9900)
        );
        streams.createStream(address(fot), payee, 10_000, 1, 1, 0, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ accrual

    function test_accrual_perSecond() public {
        uint256 id = _perSecond();
        assertEq(streams.accrued(id), 0);
        vm.warp(block.timestamp + 1);
        assertEq(streams.accrued(id), RATE);
        vm.warp(block.timestamp + 99);
        assertEq(streams.accrued(id), 100 * RATE);
        vm.warp(block.timestamp + 1_000_000);
        assertEq(streams.accrued(id), DEPOSIT, "capped at deposit");
    }

    function test_accrual_recurringInArrears() public {
        uint256 id = _monthly(12, 0);
        vm.warp(block.timestamp + 30 days - 1);
        assertEq(streams.accrued(id), 0, "nothing before the first full interval");
        vm.warp(block.timestamp + 1);
        assertEq(streams.accrued(id), 10 * USDC_UNIT);
        vm.warp(block.timestamp + 59 days);
        assertEq(streams.accrued(id), 20 * USDC_UNIT, "floors partial intervals");
        vm.warp(block.timestamp + 10 * 365 days);
        assertEq(streams.accrued(id), 120 * USDC_UNIT);
    }

    function test_accrual_partialFinalPayment() public {
        vm.prank(payer);
        uint256 id = streams.createStream(address(usdc), payee, 25, 10, 1 days, 0, 0);
        vm.warp(block.timestamp + 3 days);
        assertEq(streams.accrued(id), 25);
    }

    function test_accrual_stopsAtStop() public {
        uint64 stop = uint64(block.timestamp + 100);
        vm.prank(payer);
        uint256 id = streams.createStream(address(usdc), payee, DEPOSIT, RATE, 1, 0, stop);
        vm.warp(block.timestamp + 500);
        assertEq(streams.accrued(id), 100 * RATE);
    }

    function test_accrual_futureStart() public {
        uint64 start = uint64(block.timestamp + 1 hours);
        vm.prank(payer);
        uint256 id = streams.createStream(address(usdc), payee, DEPOSIT, RATE, 1, start, 0);
        vm.warp(start);
        assertEq(streams.accrued(id), 0);
        vm.warp(start + 10);
        assertEq(streams.accrued(id), 10 * RATE);
    }

    // ------------------------------------------------------------------ settle

    function test_settle_anyonePaysAccruedToPayee() public {
        uint256 id = _perSecond();
        vm.warp(block.timestamp + 600);
        vm.expectEmit(true, true, true, true, address(streams));
        emit IPaymentStreams.StreamSettled(id, payee, keeper, address(usdc), 600 * RATE);
        vm.prank(keeper);
        assertEq(streams.settle(id), 600 * RATE);
        assertEq(usdc.balanceOf(payee), 600 * RATE);
        assertEq(usdc.balanceOf(keeper), 0);
        assertEq(streams.getStream(id).paid, 600 * RATE);
        assertEq(streams.settleable(id), 0);
        assertEq(streams.totalOutstanding(address(usdc)), DEPOSIT - 600 * RATE);

        vm.warp(block.timestamp + 100);
        assertEq(streams.settleable(id), 100 * RATE);
        streams.settle(id);
        assertEq(usdc.balanceOf(payee), 700 * RATE);
    }

    function test_settle_nothingDueReturnsZeroWithoutEvent() public {
        uint256 id = _perSecond();
        vm.recordLogs();
        assertEq(streams.settle(id), 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_settle_unknownStreamReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.StreamNotFound.selector, 5));
        streams.settle(5);
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.StreamNotFound.selector, 5));
        streams.accrued(5);
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.StreamNotFound.selector, 5));
        streams.settleable(5);
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.StreamNotFound.selector, 5));
        streams.outstanding(5);
    }

    // ------------------------------------------------------------------ top up

    function test_topUp_extendsStream() public {
        uint256 id = _perSecond();
        vm.warp(block.timestamp + 1800);
        vm.expectEmit(true, true, false, true, address(streams));
        emit IPaymentStreams.StreamToppedUp(id, payer, DEPOSIT, 2 * DEPOSIT);
        vm.prank(payer);
        streams.topUp(id, DEPOSIT);
        assertEq(streams.getStream(id).deposit, 2 * DEPOSIT);
        assertEq(streams.totalOutstanding(address(usdc)), 2 * DEPOSIT);
        vm.warp(block.timestamp + 10_000);
        assertEq(streams.accrued(id), 2 * DEPOSIT);
    }

    function test_topUp_afterRunningDry_paysBackImmediately() public {
        uint256 id = _perSecond();
        vm.warp(block.timestamp + 7200); // ran dry after 3600s
        assertEq(streams.accrued(id), DEPOSIT);
        vm.prank(payer);
        streams.topUp(id, DEPOSIT);
        // documented debt-clock semantics: the unfunded hour is owed at once
        assertEq(streams.accrued(id), 2 * DEPOSIT);
    }

    function test_topUp_reverts() public {
        uint256 id = _perSecond();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.Unauthorized.selector, stranger));
        streams.topUp(id, 1);
        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.Unauthorized.selector, payee));
        streams.topUp(id, 1);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.InvalidAmount.selector, 0));
        streams.topUp(id, 0);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.StreamNotFound.selector, 9));
        streams.topUp(9, 1);

        uint256 overflow = uint256(type(uint128).max) - DEPOSIT + 1;
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(IPaymentStreams.DepositOverflow.selector, uint256(type(uint128).max) + 1)
        );
        streams.topUp(id, overflow);

        vm.prank(payer);
        streams.cancel(id);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.StreamIsCanceled.selector, id));
        streams.topUp(id, 1);
    }

    function test_topUp_revertsAfterStop() public {
        uint64 stop = uint64(block.timestamp + 100);
        vm.prank(payer);
        uint256 id = streams.createStream(address(usdc), payee, DEPOSIT, RATE, 1, 0, stop);
        vm.warp(stop);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.StreamEnded.selector, id, stop));
        streams.topUp(id, 1);
    }

    // ------------------------------------------------------------------ cancel

    function test_cancel_byPayer_settlesAndRefunds() public {
        uint256 id = _perSecond();
        vm.warp(block.timestamp + 1000);
        uint256 payerBefore = usdc.balanceOf(payer);
        vm.expectEmit(true, true, false, true, address(streams));
        emit IPaymentStreams.StreamCanceled(id, payer, address(usdc), 1000 * RATE, DEPOSIT - 1000 * RATE);
        vm.prank(payer);
        (uint256 toPayee, uint256 refunded) = streams.cancel(id);

        assertEq(toPayee, 1000 * RATE);
        assertEq(refunded, DEPOSIT - 1000 * RATE);
        assertEq(usdc.balanceOf(payee), 1000 * RATE);
        assertEq(usdc.balanceOf(payer), payerBefore + DEPOSIT - 1000 * RATE);
        assertEq(usdc.balanceOf(address(streams)), 0);
        assertEq(streams.totalOutstanding(address(usdc)), 0);
        IPaymentStreams.Stream memory s = streams.getStream(id);
        assertTrue(s.canceled);
        assertEq(s.paid + s.refunded, s.deposit);
        assertEq(s.stop, block.timestamp);

        // accrual is frozen
        vm.warp(block.timestamp + 10_000);
        assertEq(streams.accrued(id), 1000 * RATE);
        assertEq(streams.settle(id), 0);
    }

    function test_cancel_byPayee() public {
        uint256 id = _perSecond();
        vm.warp(block.timestamp + 10);
        vm.prank(payee);
        streams.cancel(id);
        assertEq(usdc.balanceOf(payee), 10 * RATE);
        assertTrue(streams.getStream(id).canceled);
    }

    function test_cancel_beforeStart_refundsEverything() public {
        uint64 start = uint64(block.timestamp + 1 days);
        vm.prank(payer);
        uint256 id = streams.createStream(address(usdc), payee, DEPOSIT, RATE, 1, start, 0);
        vm.prank(payer);
        (uint256 toPayee, uint256 refunded) = streams.cancel(id);
        assertEq(toPayee, 0);
        assertEq(refunded, DEPOSIT);
        assertEq(streams.getStream(id).stop, start, "frozen at start");
        vm.warp(start + 1 days);
        assertEq(streams.accrued(id), 0);
    }

    function test_cancel_afterStop_keepsEarlierStop() public {
        uint64 stop = uint64(block.timestamp + 100);
        vm.prank(payer);
        uint256 id = streams.createStream(address(usdc), payee, DEPOSIT, RATE, 1, 0, stop);
        vm.warp(stop + 50);
        vm.prank(payer);
        (uint256 toPayee, uint256 refunded) = streams.cancel(id);
        assertEq(toPayee, 100 * RATE);
        assertEq(refunded, DEPOSIT - 100 * RATE);
        assertEq(streams.getStream(id).stop, stop);
    }

    function test_cancel_fullyAccrued_noRefund() public {
        uint256 id = _perSecond();
        vm.warp(block.timestamp + 5000);
        streams.settle(id);
        vm.recordLogs();
        vm.prank(payer);
        (uint256 toPayee, uint256 refunded) = streams.cancel(id);
        assertEq(toPayee, 0);
        assertEq(refunded, 0);
        assertEq(vm.getRecordedLogs().length, 1, "only StreamCanceled");
    }

    function test_cancel_reverts() public {
        uint256 id = _perSecond();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.Unauthorized.selector, stranger));
        streams.cancel(id);
        vm.prank(payer);
        streams.cancel(id);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IPaymentStreams.StreamIsCanceled.selector, id));
        streams.cancel(id);
    }

    /// @notice USDC freezing the payee must not trap the payer's refund.
    function test_cancel_blacklistedPayee_defersPayeeButRefundsPayer() public {
        uint256 id = _perSecond();
        vm.warp(block.timestamp + 1000);
        usdc.blacklist(payee);
        uint256 payerBefore = usdc.balanceOf(payer);

        vm.expectEmit(true, true, false, true, address(streams));
        emit IPaymentStreams.StreamSettlementDeferred(id, payee, 1000 * RATE);
        vm.prank(payer);
        (uint256 toPayee, uint256 refunded) = streams.cancel(id);

        assertEq(toPayee, 0);
        assertEq(refunded, DEPOSIT - 1000 * RATE);
        assertEq(usdc.balanceOf(payer), payerBefore + refunded);
        assertEq(streams.settleable(id), 1000 * RATE);
        assertEq(streams.outstanding(id), 1000 * RATE);
        assertEq(streams.totalOutstanding(address(usdc)), 1000 * RATE);

        // still owed, never lost: once unfrozen anyone can settle
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        streams.settle(id);
        usdc.unBlacklist(payee);
        assertEq(streams.settle(id), 1000 * RATE);
        assertEq(usdc.balanceOf(payee), 1000 * RATE);
        assertEq(streams.outstanding(id), 0);
    }

    function test_cancel_blacklistedPayer_payeeStillSettles() public {
        uint256 id = _perSecond();
        vm.warp(block.timestamp + 100);
        usdc.blacklist(payer);
        vm.prank(payee);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        streams.cancel(id);
        streams.settle(id);
        assertEq(usdc.balanceOf(payee), 100 * RATE);
    }

    // ------------------------------------------------------------------ pause guardian

    function test_pause_blocksCreateAndTopUp_neverExits() public {
        uint256 id = _perSecond();
        vm.prank(guardian);
        streams.pause();

        vm.startPrank(payer);
        vm.expectRevert(GuardianPausable.NewDepositsPaused.selector);
        streams.createStream(address(usdc), payee, DEPOSIT, RATE, 1, 0, 0);
        vm.expectRevert(GuardianPausable.NewDepositsPaused.selector);
        streams.topUp(id, 1);
        vm.stopPrank();

        vm.warp(block.timestamp + 10);
        streams.settle(id);
        vm.prank(payer);
        streams.cancel(id);
        assertEq(usdc.balanceOf(address(streams)), 0);
    }

    // ------------------------------------------------------------------ reentrancy

    function test_reentrancy_tokenCallbackCannotReenter() public {
        CallbackToken cbk = new CallbackToken();
        cbk.mint(payer, 1_000_000);
        vm.prank(payer);
        cbk.approve(address(streams), type(uint256).max);
        vm.prank(payer);
        uint256 id = streams.createStream(address(cbk), payee, 1000, 1, 1, 0, 0);
        vm.warp(block.timestamp + 10);

        cbk.setCallback(address(streams), abi.encodeCall(PaymentStreams.settle, (id)));
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        streams.settle(id);

        cbk.setCallback(address(streams), abi.encodeCall(PaymentStreams.cancel, (id)));
        vm.prank(payer);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        streams.topUp(id, 10);
    }

    // ------------------------------------------------------------------ fuzz

    /// @notice accrued(t) matches the reference formula for arbitrary parameters and times.
    function testFuzz_accrual_matchesFormula(
        uint256 deposit,
        uint256 rate,
        uint64 interval,
        uint64 startDelay,
        uint64 duration,
        uint64 elapsed
    ) public {
        deposit = bound(deposit, 1, type(uint128).max);
        rate = bound(rate, 1, type(uint128).max);
        interval = uint64(bound(interval, 1, 400 days));
        startDelay = uint64(bound(startDelay, 0, 30 days));
        duration = uint64(bound(duration, 0, 10 * 365 days));
        elapsed = uint64(bound(elapsed, 0, 20 * 365 days));
        uint64 start = uint64(block.timestamp) + startDelay;
        uint64 stop = duration == 0 ? 0 : start + duration;

        usdc.mint(payer, deposit);
        vm.prank(payer);
        usdc.approve(address(streams), type(uint256).max);
        vm.prank(payer);
        uint256 id = streams.createStream(address(usdc), payee, deposit, rate, interval, start, stop);

        vm.warp(block.timestamp + elapsed);
        uint256 end = block.timestamp;
        if (stop != 0 && stop < end) end = stop;
        uint256 expected = end <= start ? 0 : ((end - start) / interval) * rate;
        if (expected > deposit) expected = deposit;
        assertEq(streams.accrued(id), expected);
    }

    /// @notice Cancel splits the deposit exactly between payee and payer, at any time, after any settlements.
    function testFuzz_cancel_conservesDeposit(
        uint256 deposit,
        uint256 rate,
        uint64 interval,
        uint32 settleAt,
        uint32 cancelAt,
        bool payeeCancels
    ) public {
        deposit = bound(deposit, 1, 1e18);
        rate = bound(rate, 1, 1e18);
        interval = uint64(bound(interval, 1, 30 days));
        settleAt = uint32(bound(settleAt, 0, 365 days));
        cancelAt = uint32(bound(cancelAt, settleAt, 2 * 365 days));

        usdc.mint(payer, deposit);
        uint256 payerBefore = usdc.balanceOf(payer);
        vm.startPrank(payer);
        usdc.approve(address(streams), type(uint256).max);
        uint256 id = streams.createStream(address(usdc), payee, deposit, rate, interval, 0, 0);
        vm.stopPrank();
        uint256 t0 = block.timestamp;

        vm.warp(t0 + settleAt);
        streams.settle(id);
        vm.warp(t0 + cancelAt);
        uint256 accruedAtCancel = streams.accrued(id);
        vm.prank(payeeCancels ? payee : payer);
        (, uint256 refunded) = streams.cancel(id);

        assertEq(usdc.balanceOf(payee), accruedAtCancel);
        assertEq(refunded, deposit - accruedAtCancel);
        assertEq(usdc.balanceOf(payee) + (usdc.balanceOf(payer) - (payerBefore - deposit)), deposit);
        assertEq(usdc.balanceOf(address(streams)), 0);
        IPaymentStreams.Stream memory s = streams.getStream(id);
        assertEq(uint256(s.paid) + s.refunded, s.deposit);
    }

    /// @notice Settling at arbitrary checkpoints never pays more than accrued and sums to the final accrual.
    function testFuzz_settle_monotonicAndExact(uint32[5] memory steps) public {
        uint256 id = _perSecond();
        uint256 paid;
        for (uint256 i; i < steps.length; ++i) {
            vm.warp(block.timestamp + bound(steps[i], 0, 2 hours));
            uint256 accruedNow = streams.accrued(id);
            paid += streams.settle(id);
            assertEq(paid, accruedNow);
            assertLe(paid, DEPOSIT);
            assertEq(usdc.balanceOf(payee), paid);
        }
    }
}
