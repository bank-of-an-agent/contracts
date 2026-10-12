// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IPaymentStreams} from "./interfaces/IPaymentStreams.sol";
import {GuardianPausable} from "./utils/GuardianPausable.sol";
import {TokenTransfer} from "./utils/TokenTransfer.sol";

/// @title PaymentStreams
/// @author Agent Bank
/// @notice Pre-funded per-second streams and recurring payments with one formula:
///         `accrued(t) = min(deposit, floor((min(t, stop) - start) / interval) * amountPerInterval)`.
///         `interval = 1` streams per second; `interval = 30 days` pays a fixed amount every 30 days (in arrears).
///         Anyone may `settle` accrued funds to the payee; only the payer may `cancel`, which settles what has
///         accrued and refunds the rest to the payer. Only the payer may `topUp` (so an agent can never be made to fund
///         someone else's stream).
/// @dev Non-custodial: no owner, no admin withdrawal, no upgradeability. The pause guardian can only stop new streams
///      and top-ups. Invariants: per stream `paid + refunded <= deposit`; per token
///      `balanceOf(this) >= totalOutstanding[token] == sum(deposit - paid - refunded)`.
///      Top-ups after a stream ran dry pay the accrued-but-unfunded periods immediately (the formula is a debt
///      clock); cancel and re-create a stream to avoid back-pay.
contract PaymentStreams is IPaymentStreams, GuardianPausable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 private _streamCount;
    mapping(uint256 id => Stream) private _streams;

    /// @inheritdoc IPaymentStreams
    mapping(address token => uint256) public override totalOutstanding;

    /// @param pauseGuardian_ Address that may pause new streams and top-ups (address(0) for none).
    constructor(address pauseGuardian_) GuardianPausable(pauseGuardian_) {}

    // ---------------------------------------------------------------------------------------------------------------
    // Mutating functions
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Creates a stream funded with `deposit` of `token` pulled from the caller (the payer).
    /// @param token ERC-20 token.
    /// @param payee Recipient. Must differ from the payer and this contract.
    /// @param deposit Initial funding (> 0, fits in uint128).
    /// @param amountPerInterval Amount that accrues per full interval (> 0, fits in uint128).
    /// @param interval Seconds per interval (> 0). 1 = per-second streaming.
    /// @param start Accrual start; 0 = now. Must not be in the past.
    /// @param stop Accrual end; 0 = open-ended (until the deposit is exhausted). Otherwise must be after `start`.
    /// @return id The new stream id.
    function createStream(
        address token,
        address payee,
        uint256 deposit,
        uint256 amountPerInterval,
        uint64 interval,
        uint64 start,
        uint64 stop
    ) external nonReentrant whenNotPaused returns (uint256 id) {
        if (token == address(0)) revert ZeroAddress();
        if (payee == address(0) || payee == msg.sender || payee == address(this)) revert InvalidPayee(payee);
        if (deposit == 0 || deposit > type(uint128).max) revert InvalidAmount(deposit);
        if (amountPerInterval == 0 || amountPerInterval > type(uint128).max) revert InvalidRate(amountPerInterval);
        if (interval == 0) revert InvalidInterval();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 effectiveStart = start == 0 ? uint64(block.timestamp) : start;
        if (effectiveStart < block.timestamp) revert InvalidStart(start);
        if (stop != 0 && stop <= effectiveStart) revert InvalidStop(stop);

        id = ++_streamCount;
        Stream storage s = _streams[id];
        s.payer = msg.sender;
        s.start = effectiveStart;
        s.payee = payee;
        s.stop = stop;
        s.token = token;
        s.interval = interval;
        // forge-lint: disable-next-line(unsafe-typecast)
        s.amountPerInterval = uint128(amountPerInterval); // bounded above
        // forge-lint: disable-next-line(unsafe-typecast)
        s.deposit = uint128(deposit); // bounded above
        totalOutstanding[token] += deposit;
        emit StreamCreated(id, msg.sender, payee, token, deposit, amountPerInterval, interval, effectiveStart, stop);

        TokenTransfer.pullExact(token, deposit);
    }

    /// @notice Adds `amount` to a live stream's deposit, pulled from the payer.
    /// @dev Payer only (so a third party cannot route funds into someone else's stream). Reverts once the stream is
    ///      canceled or past its `stop`.
    /// @param id Stream id.
    /// @param amount Amount to add (> 0; the new deposit must fit in uint128).
    function topUp(uint256 id, uint256 amount) external nonReentrant whenNotPaused {
        Stream storage s = _existing(id);
        if (msg.sender != s.payer) revert Unauthorized(msg.sender);
        if (s.canceled) revert StreamIsCanceled(id);
        uint64 stop = s.stop;
        if (stop != 0 && block.timestamp >= stop) revert StreamEnded(id, stop);
        if (amount == 0) revert InvalidAmount(0);
        uint256 newDeposit = uint256(s.deposit) + amount;
        if (newDeposit > type(uint128).max) revert DepositOverflow(newDeposit);

        // forge-lint: disable-next-line(unsafe-typecast)
        s.deposit = uint128(newDeposit); // bounded above
        address token = s.token;
        totalOutstanding[token] += amount;
        emit StreamToppedUp(id, msg.sender, amount, newDeposit);

        TokenTransfer.pullExact(token, amount);
    }

    /// @notice Pays everything accrued but not yet paid to the payee. Callable by anyone (keepers).
    /// @param id Stream id.
    /// @return amount Amount paid (0 if nothing is due; no transfer and no event in that case).
    function settle(uint256 id) external nonReentrant returns (uint256 amount) {
        Stream storage s = _existing(id);
        uint256 accruedNow = _accruedAt(s, block.timestamp);
        amount = accruedNow - s.paid;
        if (amount == 0) return 0;

        // forge-lint: disable-next-line(unsafe-typecast)
        s.paid = uint128(accruedNow); // accrued <= deposit <= uint128 max
        address token = s.token;
        address payee = s.payee;
        totalOutstanding[token] -= amount;
        emit StreamSettled(id, payee, msg.sender, token, amount);

        IERC20(token).safeTransfer(payee, amount);
    }

    /// @notice Cancels the stream: freezes accrual now, pays the payee what has accrued, refunds the rest to the payer.
    /// @dev Payer only. The payer's refund never depends on the payee being able to receive: if paying the payee
    ///      fails (e.g. the token froze the payee), that amount stays settleable via `settle` and
    ///      `StreamSettlementDeferred` is emitted.
    /// @param id Stream id.
    /// @return payeeAmount Amount paid to the payee in this call.
    /// @return refundAmount Amount refunded to the payer.
    function cancel(uint256 id) external nonReentrant returns (uint256 payeeAmount, uint256 refundAmount) {
        Stream storage s = _existing(id);
        address payer = s.payer;
        if (msg.sender != payer) revert Unauthorized(msg.sender);
        if (s.canceled) revert StreamIsCanceled(id);
        address payee = s.payee;

        uint256 accruedNow = _accruedAt(s, block.timestamp);
        // Freeze accrual at max(now, start) so accrued(t) stays equal to accruedNow forever.
        uint256 frozenAt = block.timestamp < s.start ? s.start : block.timestamp;
        if (s.stop == 0 || s.stop > frozenAt) {
            // forge-lint: disable-next-line(unsafe-typecast)
            s.stop = uint64(frozenAt);
        }
        s.canceled = true;
        refundAmount = s.deposit - accruedNow;
        // forge-lint: disable-next-line(unsafe-typecast)
        s.refunded = uint128(refundAmount); // <= deposit
        address token = s.token;
        totalOutstanding[token] -= refundAmount;

        uint256 owed = accruedNow - s.paid;
        if (owed != 0) {
            uint128 paidBefore = s.paid;
            // forge-lint: disable-next-line(unsafe-typecast)
            s.paid = uint128(accruedNow);
            totalOutstanding[token] -= owed;
            if (TokenTransfer.tryPushExact(token, payee, owed)) {
                payeeAmount = owed;
                emit StreamSettled(id, payee, msg.sender, token, owed);
            } else {
                // Roll the optimistic settlement back; the payee can `settle` later.
                s.paid = paidBefore;
                totalOutstanding[token] += owed;
                emit StreamSettlementDeferred(id, payee, owed);
            }
        }
        emit StreamCanceled(id, msg.sender, token, payeeAmount, refundAmount);

        if (refundAmount != 0) IERC20(token).safeTransfer(payer, refundAmount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IPaymentStreams
    function getStream(uint256 id) external view returns (Stream memory) {
        return _streams[id];
    }

    /// @inheritdoc IPaymentStreams
    function accrued(uint256 id) external view returns (uint256) {
        return _accruedAt(_existing(id), block.timestamp);
    }

    /// @inheritdoc IPaymentStreams
    function settleable(uint256 id) external view returns (uint256) {
        Stream storage s = _existing(id);
        return _accruedAt(s, block.timestamp) - s.paid;
    }

    /// @inheritdoc IPaymentStreams
    function outstanding(uint256 id) external view returns (uint256) {
        Stream storage s = _existing(id);
        return uint256(s.deposit) - s.paid - s.refunded;
    }

    /// @inheritdoc IPaymentStreams
    function streamCount() external view returns (uint256) {
        return _streamCount;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    function _existing(uint256 id) private view returns (Stream storage s) {
        s = _streams[id];
        if (s.payer == address(0)) revert StreamNotFound(id);
    }

    /// @dev `min(deposit, floor((min(t, stop) - start) / interval) * amountPerInterval)`, 0 before `start`.
    ///      Cannot overflow: elapsed < 2^64 and amountPerInterval < 2^128.
    function _accruedAt(Stream storage s, uint256 t) private view returns (uint256) {
        uint256 end = t;
        uint256 stop = s.stop;
        if (stop != 0 && stop < end) end = stop;
        uint256 start = s.start;
        if (end <= start) return 0;
        // Intentional floor: only completed intervals accrue (recurring payments are paid per whole period).
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 earned = ((end - start) / s.interval) * s.amountPerInterval;
        uint256 deposit = s.deposit;
        return earned < deposit ? earned : deposit;
    }
}
