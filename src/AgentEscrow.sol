// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IAgentEscrow} from "./interfaces/IAgentEscrow.sol";
import {IERC8004ValidationRegistry} from "./interfaces/IERC8004ValidationRegistry.sol";
import {GuardianPausable} from "./utils/GuardianPausable.sol";
import {TokenTransfer} from "./utils/TokenTransfer.sol";

/// @title AgentEscrow
/// @author Agent Bank
/// @notice Singleton multi-escrow for agent-to-agent work. A payer (an agent's smart account) locks tokens for a
///         payee. Funds leave ONLY to the payer or the payee:
///         - `release`: the payer, or the arbiter, pays the payee;
///         - `releaseByValidation`: anyone, once the payer-chosen ERC-8004 validator approved the request (before expiry);
///         - `refund`: the payee anytime; anyone after `expiresAt` if not disputed;
///         - `dispute` (payer/payee, before expiry) hands the decision to the arbiter, who `resolve`s with a split;
///         - liveness: a dispute left unresolved until `expiresAt + DISPUTE_TIMEOUT` is refundable by anyone.
/// @dev Non-custodial: no owner, no admin withdrawal, no upgradeability. The pause guardian can only stop new `lock`s.
///      Invariant: `balanceOf(this) >= totalLocked[token]` for every token (exact-amount pulls; see TokenTransfer).
contract AgentEscrow is IAgentEscrow, GuardianPausable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice How long after expiry a disputed escrow waits for the arbiter before anyone may refund the payer.
    uint64 public constant DISPUTE_TIMEOUT = 30 days;
    /// @notice Longest allowed escrow life (bounds how long funds can be frozen by a dispute).
    uint64 public constant MAX_ESCROW_DURATION = 365 days;
    /// @notice Highest ERC-8004 validation response.
    uint8 public constant MAX_VALIDATION_RESPONSE = 100;

    /// @notice ERC-8004 Validation Registry consulted by `releaseByValidation` (address(0): validation disabled).
    IERC8004ValidationRegistry public immutable VALIDATION_REGISTRY;

    uint256 private _escrowCount;
    mapping(uint256 id => Escrow) private _escrows;

    /// @inheritdoc IAgentEscrow
    mapping(address token => uint256) public override totalLocked;

    /// @param pauseGuardian_ Address that may pause new locks (address(0) for none).
    /// @param validationRegistry_ ERC-8004 Validation Registry (address(0) disables the validator path).
    constructor(address pauseGuardian_, address validationRegistry_) GuardianPausable(pauseGuardian_) {
        if (validationRegistry_ != address(0) && validationRegistry_.code.length == 0) {
            revert InvalidValidationRegistry(validationRegistry_);
        }
        VALIDATION_REGISTRY = IERC8004ValidationRegistry(validationRegistry_);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Mutating functions
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Locks `amount` of `token` from the caller (the payer) in a new escrow for `payee`.
    /// @dev Pulls with `transferFrom`; the payer must have approved this contract. Fee-on-transfer tokens revert.
    /// @param token ERC-20 token to escrow.
    /// @param payee Recipient on release. Must differ from the payer and this contract.
    /// @param amount Amount in token units (> 0).
    /// @param expiresAt Unix time after which anyone may refund an undisputed escrow
    ///        (in `(now, now + MAX_ESCROW_DURATION]`).
    /// @param arbiter Optional third party that may release and resolves disputes (address(0) for none;
    ///        without an arbiter the escrow cannot be disputed).
    /// @param validator Optional ERC-8004 validator whose response may release the escrow (address(0) for none).
    /// @param validationRequestHash ERC-8004 request hash the validator must answer (0 iff no validator).
    /// @param validationThreshold Minimum response, 1..100 (0 iff no validator).
    /// @param termsHash Commitment to the off-chain terms; stored and emitted for reconciliation.
    /// @return id The new escrow id.
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
    ) external nonReentrant whenNotPaused returns (uint256 id) {
        _validateLock(token, payee, amount, expiresAt, arbiter);
        _validateValidation(payee, validator, validationRequestHash, validationThreshold);

        id = ++_escrowCount;
        Escrow storage e = _escrows[id];
        e.payer = msg.sender;
        e.expiresAt = expiresAt;
        e.status = Status.Active;
        e.validationThreshold = validationThreshold;
        e.payee = payee;
        // forge-lint: disable-next-line(unsafe-typecast)
        e.createdAt = uint64(block.timestamp); // uint64 seconds outlast the chain
        e.token = token;
        e.arbiter = arbiter;
        e.amount = amount;
        e.termsHash = termsHash;
        if (validator != address(0)) {
            e.validator = validator;
            e.validationRequestHash = validationRequestHash;
            emit ValidationConfigured(id, validator, validationRequestHash, validationThreshold);
        }
        totalLocked[token] += amount;
        emit Locked(id, msg.sender, payee, token, amount, expiresAt, arbiter, termsHash);

        TokenTransfer.pullExact(token, msg.sender, amount);
    }

    /// @notice Pays the full escrowed amount to the payee.
    /// @dev Callable by the payer or the arbiter while the escrow is Active or Disputed, at any time.
    /// @param id Escrow id.
    function release(uint256 id) external nonReentrant {
        Escrow storage e = _escrows[id];
        _requireOpen(id, e.status);
        ReleaseReason reason;
        if (msg.sender == e.payer) {
            reason = ReleaseReason.PayerApproval;
        } else if (msg.sender == e.arbiter) {
            // e.arbiter == address(0) can never match msg.sender
            reason = ReleaseReason.ArbiterDecision;
        } else {
            revert Unauthorized(msg.sender);
        }
        _release(id, e, reason);
    }

    /// @notice Pays the payee once the configured ERC-8004 validator approved the request. Callable by anyone.
    /// @dev Requires: status Active (a dispute suspends this path), `block.timestamp < expiresAt`, the registry's
    ///      validator for `validationRequestHash` equals the escrow's validator, the latest response is
    ///      `>= validationThreshold`, and the response is not older than the escrow (`lastUpdate >= createdAt`).
    /// @param id Escrow id.
    function releaseByValidation(uint256 id) external nonReentrant {
        Escrow storage e = _escrows[id];
        bytes memory failure = _validationFailure(id, e);
        if (failure.length != 0) {
            assembly ("memory-safe") {
                revert(add(failure, 0x20), mload(failure))
            }
        }
        _release(id, e, ReleaseReason.Validation);
    }

    /// @notice Returns the full escrowed amount to the payer.
    /// @dev The payee may refund at any time (Active or Disputed). Anyone may refund an Active escrow at or after
    ///      `expiresAt`, and a Disputed escrow at or after `expiresAt + DISPUTE_TIMEOUT` (liveness guarantee).
    /// @param id Escrow id.
    function refund(uint256 id) external nonReentrant {
        Escrow storage e = _escrows[id];
        Status status = e.status;
        _requireOpen(id, status);

        RefundReason reason;
        if (msg.sender == e.payee) {
            reason = RefundReason.PayeeVoluntary;
        } else {
            uint256 availableAt = _refundableAt(e.expiresAt, status);
            if (block.timestamp < availableAt) revert RefundNotYetAvailable(id, availableAt);
            reason = status == Status.Active ? RefundReason.Expired : RefundReason.DisputeTimeout;
        }

        e.status = Status.Refunded;
        address token = e.token;
        address payer = e.payer;
        uint256 amount = e.amount;
        totalLocked[token] -= amount;
        emit Refunded(id, payer, msg.sender, token, amount, reason);

        IERC20(token).safeTransfer(payer, amount);
    }

    /// @notice Disputes an Active escrow, freezing it for the arbiter. Payer or payee, strictly before expiry.
    /// @dev Requires an arbiter. While Disputed, the validator path is suspended; the payer can still release, the
    ///      payee can still refund, the arbiter can release or resolve, and after `expiresAt + DISPUTE_TIMEOUT`
    ///      anyone can refund the payer.
    /// @param id Escrow id.
    function dispute(uint256 id) external nonReentrant {
        Escrow storage e = _escrows[id];
        if (e.status != Status.Active) revert InvalidStatus(id, e.status);
        if (msg.sender != e.payer && msg.sender != e.payee) revert Unauthorized(msg.sender);
        if (e.arbiter == address(0)) revert NoArbiter(id);
        if (block.timestamp >= e.expiresAt) revert EscrowExpired(id, e.expiresAt);

        e.status = Status.Disputed;
        emit Disputed(id, msg.sender, uint256(e.expiresAt) + DISPUTE_TIMEOUT);
    }

    /// @notice Settles a disputed escrow: `payeeAmount` to the payee and the remainder to the payer. Arbiter only.
    /// @param id Escrow id.
    /// @param payeeAmount Portion for the payee (0..amount).
    function resolve(uint256 id, uint256 payeeAmount) external nonReentrant {
        Escrow storage e = _escrows[id];
        if (e.status != Status.Disputed) revert InvalidStatus(id, e.status);
        if (msg.sender != e.arbiter) revert Unauthorized(msg.sender);
        uint256 amount = e.amount;
        if (payeeAmount > amount) revert InvalidResolution(id, payeeAmount, amount);

        e.status = Status.Resolved;
        address token = e.token;
        uint256 payerAmount = amount - payeeAmount;
        totalLocked[token] -= amount;
        emit Resolved(id, msg.sender, token, payeeAmount, payerAmount);

        if (payeeAmount != 0) IERC20(token).safeTransfer(e.payee, payeeAmount);
        if (payerAmount != 0) IERC20(token).safeTransfer(e.payer, payerAmount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAgentEscrow
    function getEscrow(uint256 id) external view returns (Escrow memory) {
        return _escrows[id];
    }

    /// @inheritdoc IAgentEscrow
    function escrowCount() external view returns (uint256) {
        return _escrowCount;
    }

    /// @inheritdoc IAgentEscrow
    function refundableAt(uint256 id) external view returns (uint256) {
        Escrow storage e = _escrows[id];
        Status status = e.status;
        if (status != Status.Active && status != Status.Disputed) return 0;
        return _refundableAt(e.expiresAt, status);
    }

    /// @inheritdoc IAgentEscrow
    function checkValidation(uint256 id) external view returns (bool satisfied, bytes memory reason) {
        reason = _validationFailure(id, _escrows[id]);
        satisfied = reason.length == 0;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    function _release(uint256 id, Escrow storage e, ReleaseReason reason) private {
        e.status = Status.Released;
        address token = e.token;
        address payee = e.payee;
        uint256 amount = e.amount;
        totalLocked[token] -= amount;
        // The only external call that can precede this event is the view-only registry read in releaseByValidation
        // (a STATICCALL, which cannot reenter state changes); every entry point is also nonReentrant.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Released(id, payee, msg.sender, token, amount, reason);

        IERC20(token).safeTransfer(payee, amount);
    }

    function _requireOpen(uint256 id, Status status) private pure {
        if (status != Status.Active && status != Status.Disputed) revert InvalidStatus(id, status);
    }

    function _refundableAt(uint64 expiresAt, Status status) private pure returns (uint256) {
        return status == Status.Disputed ? uint256(expiresAt) + DISPUTE_TIMEOUT : uint256(expiresAt);
    }

    function _validateLock(address token, address payee, uint256 amount, uint64 expiresAt, address arbiter)
        private
        view
    {
        if (token == address(0)) revert ZeroAddress();
        if (payee == address(0) || payee == msg.sender || payee == address(this)) revert InvalidPayee(payee);
        if (amount == 0) revert InvalidAmount();
        if (expiresAt <= block.timestamp || expiresAt > block.timestamp + MAX_ESCROW_DURATION) {
            revert InvalidExpiry(expiresAt);
        }
        if (arbiter != address(0) && (arbiter == msg.sender || arbiter == payee || arbiter == address(this))) {
            revert InvalidArbiter(arbiter);
        }
    }

    function _validateValidation(address payee, address validator, bytes32 requestHash, uint8 threshold) private view {
        if (validator == address(0)) {
            if (requestHash != bytes32(0) || threshold != 0) revert InvalidValidationConfig();
            return;
        }
        if (address(VALIDATION_REGISTRY) == address(0)) revert ValidationUnsupported();
        if (validator == payee || validator == address(this)) revert InvalidValidator(validator);
        // threshold >= 1: the registry has no "responded" flag, so 0 would accept an unanswered request.
        if (requestHash == bytes32(0) || threshold == 0 || threshold > MAX_VALIDATION_RESPONSE) {
            revert InvalidValidationConfig();
        }
    }

    /// @dev Empty when `releaseByValidation(id)` may proceed; otherwise the ABI-encoded custom error explaining why.
    function _validationFailure(uint256 id, Escrow storage e) private view returns (bytes memory) {
        Status status = e.status;
        if (status != Status.Active) return abi.encodeWithSelector(InvalidStatus.selector, id, status);
        address validator = e.validator;
        if (validator == address(0)) return abi.encodeWithSelector(NoValidator.selector, id);
        if (block.timestamp >= e.expiresAt) return abi.encodeWithSelector(EscrowExpired.selector, id, e.expiresAt);

        bytes32 requestHash = e.validationRequestHash;
        try VALIDATION_REGISTRY.getValidationStatus(requestHash) returns (
            address validatorAddress, uint256, uint8 response, bytes32, string memory, uint256 lastUpdate
        ) {
            if (validatorAddress != validator) {
                return abi.encodeWithSelector(ValidatorMismatch.selector, id, validator, validatorAddress);
            }
            if (lastUpdate < e.createdAt) {
                return abi.encodeWithSelector(ValidationStale.selector, id, lastUpdate, e.createdAt);
            }
            if (response < e.validationThreshold) {
                return abi.encodeWithSelector(ValidationBelowThreshold.selector, id, response, e.validationThreshold);
            }
            return "";
        } catch {
            return abi.encodeWithSelector(ValidationNotFound.selector, id, requestHash);
        }
    }
}
