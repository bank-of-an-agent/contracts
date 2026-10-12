// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @title IAgentEscrow
/// @notice Types, events, errors and functions of the Agent Bank singleton escrow.
interface IAgentEscrow {
    /// @notice Escrow lifecycle. Released, Refunded and Resolved are terminal.
    enum Status {
        None,
        Active,
        Disputed,
        Released,
        Refunded,
        Resolved
    }

    /// @notice Why funds were released to the payee.
    enum ReleaseReason {
        PayerApproval,
        ArbiterDecision,
        Validation
    }

    /// @notice Why funds were refunded to the payer.
    enum RefundReason {
        PayeeVoluntary,
        Expired,
        DisputeTimeout
    }

    /// @notice One escrow. Funds can only ever leave to `payer` or `payee`.
    struct Escrow {
        address payer; // the smart account that locked the funds
        uint64 expiresAt; // refundable by anyone at/after this time unless disputed
        Status status;
        uint8 validationThreshold; // minimum ERC-8004 response (1..100) for releaseByValidation; 0 if no validator
        address payee;
        uint64 createdAt; // validation responses older than this are ignored
        address token;
        address arbiter; // optional: may release, and resolves disputes
        address validator; // optional: ERC-8004 validator whose response can release
        uint256 amount;
        bytes32 validationRequestHash; // ERC-8004 request hash; 0 if no validator
        bytes32 termsHash; // commitment to the off-chain terms (indexer/ledger reference)
    }

    /// @notice Funds were locked in a new escrow.
    event Locked(
        uint256 indexed id,
        address indexed payer,
        address indexed payee,
        address token,
        uint256 amount,
        uint64 expiresAt,
        address arbiter,
        bytes32 termsHash
    );
    /// @notice The escrow can be released by an ERC-8004 validation response.
    event ValidationConfigured(
        uint256 indexed id, address indexed validator, bytes32 indexed requestHash, uint8 threshold
    );
    /// @notice The full amount was paid to the payee.
    event Released(
        uint256 indexed id,
        address indexed payee,
        address indexed caller,
        address token,
        uint256 amount,
        ReleaseReason reason
    );
    /// @notice The full amount was returned to the payer.
    event Refunded(
        uint256 indexed id,
        address indexed payer,
        address indexed caller,
        address token,
        uint256 amount,
        RefundReason reason
    );
    /// @notice The escrow was disputed; `refundableAt` is when anyone may refund it if the arbiter stays silent.
    event Disputed(uint256 indexed id, address indexed disputant, uint256 refundableAt);
    /// @notice The arbiter split a disputed escrow.
    event Resolved(
        uint256 indexed id, address indexed arbiter, address token, uint256 payeeAmount, uint256 payerAmount
    );

    error ZeroAddress();
    error InvalidPayee(address payee);
    error InvalidAmount();
    error InvalidExpiry(uint64 expiresAt);
    error InvalidArbiter(address arbiter);
    error InvalidValidator(address validator);
    error InvalidValidationConfig();
    error InvalidValidationRegistry(address registry);
    error ValidationUnsupported();
    error InvalidStatus(uint256 id, Status status);
    error Unauthorized(address caller);
    error EscrowExpired(uint256 id, uint64 expiresAt);
    error RefundNotYetAvailable(uint256 id, uint256 refundableAt);
    error NoArbiter(uint256 id);
    error NoValidator(uint256 id);
    error ValidationNotFound(uint256 id, bytes32 requestHash);
    error ValidatorMismatch(uint256 id, address expected, address actual);
    error ValidationStale(uint256 id, uint256 lastUpdate, uint64 createdAt);
    error ValidationBelowThreshold(uint256 id, uint8 response, uint8 threshold);
    error InvalidResolution(uint256 id, uint256 payeeAmount, uint256 amount);

    /// @notice Locks `amount` of `token` from the caller (the payer) for `payee`.
    function lock(
        address token,
        address payee,
        uint256 amount,
        uint64 expiresAt,
        address arbiter,
        address validator,
        bytes32 validationRequestHash,
        uint8 validationThreshold,
        bytes32 termsHash
    ) external returns (uint256 id);

    /// @notice Pays the full amount to the payee. Payer or arbiter.
    function release(uint256 id) external;

    /// @notice Pays the payee if the configured ERC-8004 validator approved the request. Anyone.
    function releaseByValidation(uint256 id) external;

    /// @notice Returns the full amount to the payer (payee anytime; anyone after expiry / dispute timeout).
    function refund(uint256 id) external;

    /// @notice Freezes an active escrow for the arbiter. Payer or payee, before expiry.
    function dispute(uint256 id) external;

    /// @notice Splits a disputed escrow: `payeeAmount` to the payee, the rest to the payer. Arbiter only.
    function resolve(uint256 id, uint256 payeeAmount) external;

    /// @notice Full escrow record.
    function getEscrow(uint256 id) external view returns (Escrow memory);

    /// @notice Number of escrows ever created (ids are 1..escrowCount).
    function escrowCount() external view returns (uint256);

    /// @notice Sum of amounts in Active or Disputed escrows for `token`.
    function totalLocked(address token) external view returns (uint256);

    /// @notice Earliest time anyone may refund the escrow; 0 if it is not refundable by third parties.
    function refundableAt(uint256 id) external view returns (uint256);

    /// @notice Whether `releaseByValidation(id)` would succeed now, and the revert data if not.
    function checkValidation(uint256 id) external view returns (bool satisfied, bytes memory reason);
}
