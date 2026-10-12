// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IAgentAttestationRegistry} from "./interfaces/IAgentAttestationRegistry.sol";
import {IAgentClaimsVerifier} from "./interfaces/IAgentClaimsVerifier.sol";
import {AgentClaimsGroth16Verifier} from "./verifiers/AgentClaimsGroth16Verifier.sol";

/// @title AgentClaimsVerifier
/// @author Agent Bank
/// @notice Verifies agentbank.claims.v1 zero-knowledge proofs on-chain: an agent proves that a leaf in a tree whose root
///         Agent Bank published in the `AgentAttestationRegistry` is its own and that its attested attributes lie
///         within the claimed bounds, without revealing which agent it is.
///         - `verify` is a view for anyone: it checks the root and the proof and returns false on any failure. The
///           caller must build `claims` from its own request (scope, nonce, bounds), never from the prover.
///         - `verifyAndConsume` is for contracts that admit agents: the scope must be the caller's own
///           (`scopeOf(msg.sender, context)`), the nonce is consumed so a proof cannot be replayed, and the returned
///           nullifier is a stable pseudonym of the agent for that caller and context.
/// @dev Holds and moves no funds; no owner, no upgrade path. The only external calls are STATICCALLs to the registry
///      and the generated Groth16 verifier. Groth16 proofs are malleable, so replay protection is keyed on
///      (scope, nonce), which the proof binds, and never on the proof bytes.
///      Gas: a valid proof costs about 400k gas to check. A malformed proof (a point off the curve or outside the
///      subgroup) makes the BN254 pairing precompile consume all the gas forwarded to it before the check returns
///      false; contracts that relay untrusted proofs should bound the gas they forward (e.g. `verify{gas: 1_000_000}`).
contract AgentClaimsVerifier is IAgentClaimsVerifier {
    /// @inheritdoc IAgentClaimsVerifier
    uint256 public constant override ATTRIBUTE_COUNT = 13;

    /// @dev BN254 scalar field order: every public signal must be below it.
    uint256 internal constant SNARK_SCALAR_FIELD =
        21_888_242_871_839_275_222_246_405_745_257_275_088_548_364_400_416_034_343_698_204_186_575_808_495_617;

    /// @dev Domain of on-chain scopes; HTTP verifiers use "agentbank.proofs.scope.v1:" + host instead.
    string internal constant SCOPE_DOMAIN = "agentbank.proofs.scope.v1";

    /// @dev Why a check failed (None: it passed).
    enum Failure {
        None,
        RootNotValid,
        RootTooOld,
        AnonymitySetTooSmall,
        FieldElementOutOfRange,
        InvalidProof
    }

    error ZeroAddress();

    /// @inheritdoc IAgentClaimsVerifier
    address public immutable override registry;

    /// @inheritdoc IAgentClaimsVerifier
    address public immutable override groth16Verifier;

    /// @inheritdoc IAgentClaimsVerifier
    mapping(uint256 scope => mapping(uint256 nonce => bool)) public override nonceUsed;

    /// @param registry_ The AgentAttestationRegistry whose roots proofs must use.
    /// @param groth16Verifier_ The AgentClaimsGroth16Verifier generated from the circuit's proving key.
    constructor(address registry_, address groth16Verifier_) {
        if (registry_ == address(0) || groth16Verifier_ == address(0)) revert ZeroAddress();
        registry = registry_;
        groth16Verifier = groth16Verifier_;
    }

    /// @inheritdoc IAgentClaimsVerifier
    function scopeOf(address consumer, bytes32 context) public view returns (uint256) {
        return uint256(keccak256(abi.encode(SCOPE_DOMAIN, block.chainid, consumer, context))) % SNARK_SCALAR_FIELD;
    }

    /// @inheritdoc IAgentClaimsVerifier
    function verify(Claims calldata claims, Groth16Proof calldata proof, uint32 minAnonymitySet, uint64 maxRootAge)
        external
        view
        returns (bool)
    {
        (Failure failure,) = _check(claims, proof, minAnonymitySet, maxRootAge);
        return failure == Failure.None;
    }

    /// @inheritdoc IAgentClaimsVerifier
    function verifyAndConsume(
        bytes32 context,
        Claims calldata claims,
        Groth16Proof calldata proof,
        uint32 minAnonymitySet,
        uint64 maxRootAge
    ) external returns (uint256 nullifier) {
        uint256 scope = claims.scope;
        uint256 expected = scopeOf(msg.sender, context);
        if (scope != expected) revert ScopeMismatch(expected, scope);
        uint256 nonce = claims.nonce;
        if (nonceUsed[scope][nonce]) revert NonceAlreadyUsed(scope, nonce);

        (Failure failure, IAgentAttestationRegistry.RootInfo memory info) =
            _check(claims, proof, minAnonymitySet, maxRootAge);
        if (failure == Failure.RootNotValid) revert RootNotValid(claims.root);
        if (failure == Failure.RootTooOld) revert RootTooOld(claims.root, info.snapshotAt, maxRootAge);
        if (failure == Failure.AnonymitySetTooSmall) {
            revert AnonymitySetTooSmall(claims.root, info.leafCount, minAnonymitySet);
        }
        if (failure == Failure.FieldElementOutOfRange) revert FieldElementOutOfRange();
        if (failure == Failure.InvalidProof) revert InvalidProof();

        nonceUsed[scope][nonce] = true;
        nullifier = claims.nullifier;
        emit ClaimsAccepted(msg.sender, scope, nullifier, claims.root, nonce);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Never reverts: root checks, field range, then the pairing check. `info` is set once the root is valid.
    ///      The root itself needs no range check: the registry only accepts roots below the field order.
    function _check(Claims calldata claims, Groth16Proof calldata proof, uint32 minAnonymitySet, uint64 maxRootAge)
        private
        view
        returns (Failure, IAgentAttestationRegistry.RootInfo memory info)
    {
        IAgentAttestationRegistry roots = IAgentAttestationRegistry(registry);
        if (!roots.isValidRoot(claims.root)) return (Failure.RootNotValid, info);
        info = roots.rootInfo(claims.root);
        // snapshotAt <= publishedAt <= now, written so that it cannot underflow either way.
        if (maxRootAge != 0 && block.timestamp > uint256(info.snapshotAt) + maxRootAge) {
            return (Failure.RootTooOld, info);
        }
        if (info.leafCount < minAnonymitySet) return (Failure.AnonymitySetTooSmall, info);
        if (
            claims.nullifier >= SNARK_SCALAR_FIELD || claims.scope >= SNARK_SCALAR_FIELD
                || claims.nonce >= SNARK_SCALAR_FIELD
        ) return (Failure.FieldElementOutOfRange, info);

        bool ok = AgentClaimsGroth16Verifier(groth16Verifier).verifyProof(proof.a, proof.b, proof.c, _signals(claims));
        return (ok ? Failure.None : Failure.InvalidProof, info);
    }

    /// @dev Public signals in circuit order: nullifier, root, scope, nonce, mins[13], maxs[13].
    function _signals(Claims calldata claims) private pure returns (uint256[30] memory signals) {
        signals[0] = claims.nullifier;
        signals[1] = uint256(claims.root);
        signals[2] = claims.scope;
        signals[3] = claims.nonce;
        for (uint256 i; i < ATTRIBUTE_COUNT; ++i) {
            signals[4 + i] = claims.mins[i];
            signals[4 + ATTRIBUTE_COUNT + i] = claims.maxs[i];
        }
    }
}
