// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @title IPaymentStreams
/// @notice Types, events, errors and functions of the Agent Bank pre-funded streams / recurring payments.
interface IPaymentStreams {
    /// @notice One pre-funded stream. `accrued(t) = min(deposit, floor((min(t, stop) - start) / interval) * rate)`.
    /// @dev Invariants: `paid + refunded <= deposit`, `paid <= accrued`, and after cancellation
    ///      `refunded == deposit - accrued` with accrual frozen.
    struct Stream {
        address payer;
        uint64 start; // accrual starts here (in arrears: nothing is payable before start + interval)
        bool canceled;
        address payee;
        uint64 stop; // accrual ends here; 0 = open-ended (until the deposit is exhausted)
        address token;
        uint64 interval; // seconds per period; 1 = per-second streaming
        uint128 amountPerInterval;
        uint128 deposit; // total funded (initial deposit + top-ups)
        uint128 paid; // total settled to the payee
        uint128 refunded; // total returned to the payer (set once, on cancel)
    }

    /// @notice A new stream was funded.
    event StreamCreated(
        uint256 indexed id,
        address indexed payer,
        address indexed payee,
        address token,
        uint256 deposit,
        uint256 amountPerInterval,
        uint64 interval,
        uint64 start,
        uint64 stop
    );
    /// @notice The payer added funds.
    event StreamToppedUp(uint256 indexed id, address indexed payer, uint256 amount, uint256 newDeposit);
    /// @notice Accrued funds were paid to the payee.
    event StreamSettled(
        uint256 indexed id, address indexed payee, address indexed caller, address token, uint256 amount
    );
    /// @notice The stream was canceled; `payeeAmount` was paid now and `refundAmount` returned to the payer.
    event StreamCanceled(
        uint256 indexed id, address indexed canceledBy, address token, uint256 payeeAmount, uint256 refundAmount
    );
    /// @notice The payee could not be paid during cancellation (e.g. the token froze them); the amount stays
    ///         settleable via `settle`.
    event StreamSettlementDeferred(uint256 indexed id, address indexed payee, uint256 amount);

    error ZeroAddress();
    error InvalidPayee(address payee);
    error InvalidAmount(uint256 amount);
    error InvalidRate(uint256 amountPerInterval);
    error InvalidInterval();
    error InvalidStart(uint64 start);
    error InvalidStop(uint64 stop);
    error StreamNotFound(uint256 id);
    error StreamIsCanceled(uint256 id);
    error StreamEnded(uint256 id, uint64 stop);
    error Unauthorized(address caller);
    error DepositOverflow(uint256 newDeposit);

    /// @notice Creates and funds a stream from the caller (the payer) to `payee`.
    function createStream(
        address token,
        address payee,
        uint256 deposit,
        uint256 amountPerInterval,
        uint64 interval,
        uint64 start,
        uint64 stop
    ) external returns (uint256 id);

    /// @notice Adds `amount` to the stream's deposit. Payer only (nobody can route funds into another's stream).
    function topUp(uint256 id, uint256 amount) external;

    /// @notice Pays accrued-but-unpaid funds to the payee. Anyone.
    function settle(uint256 id) external returns (uint256 amount);

    /// @notice Settles accrued funds and refunds the rest to the payer. Payer only.
    function cancel(uint256 id) external returns (uint256 payeeAmount, uint256 refundAmount);

    /// @notice Full stream record.
    function getStream(uint256 id) external view returns (Stream memory);

    /// @notice Total accrued to the payee so far (paid or not).
    function accrued(uint256 id) external view returns (uint256);

    /// @notice Accrued but not yet paid (what `settle` would pay now).
    function settleable(uint256 id) external view returns (uint256);

    /// @notice Funds the contract holds for this stream (`deposit - paid - refunded`).
    function outstanding(uint256 id) external view returns (uint256);

    /// @notice Number of streams ever created (ids are 1..streamCount).
    function streamCount() external view returns (uint256);

    /// @notice Sum of `outstanding` over all streams of `token`.
    function totalOutstanding(address token) external view returns (uint256);
}
