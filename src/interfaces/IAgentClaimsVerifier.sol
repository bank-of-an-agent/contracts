// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @title IAgentClaimsVerifier
/// @notice Verifies agentbank.claims.v1 zero-knowledge proofs against roots in the
///         AgentAttestationRegistry.
/// @dev Public signals, in circuit order: nullifier, root, scope, nonce, mins[13], maxs[13].
///      Bounds are inclusive; [0, 2^64 - 1] leaves an attribute unconstrained. Attribute order:
///      principal_verification, per_tx_limit, per_day_limit, balance, reserved_amount,
///      reserved_until, reserved_for, account_created_on, payments_settled, volume_settled,
///      escrows_completed, disputes_lost, counterparties.
interface IAgentClaimsVerifier {
    /// @notice A Groth16 proof in the generated verifier's calldata order (as produced by
    ///         snarkjs `exportSolidityCallData`): `b` has each pair's coordinates swapped.
    struct Groth16Proof {
        uint256[2] a;
        uint256[2][2] b;
        uint256[2] c;
    }

    /// @notice The statement a proof is checked against.
    struct Claims {
        bytes32 root;
        uint256 nullifier;
        uint256 scope;
        uint256 nonce;
        uint64[13] mins;
        uint64[13] maxs;
    }

    event ClaimsAccepted(
        address indexed consumer, uint256 indexed scope, uint256 indexed nullifier, bytes32 root, uint256 nonce
    );

    error RootNotValid(bytes32 root);
    error RootTooOld(bytes32 root, uint64 snapshotAt, uint64 maxRootAge);
    error AnonymitySetTooSmall(bytes32 root, uint32 leafCount, uint32 minAnonymitySet);
    error InvalidProof();
    error ScopeMismatch(uint256 expected, uint256 actual);
    error NonceAlreadyUsed(uint256 scope, uint256 nonce);
    error FieldElementOutOfRange();

    /// @notice 13.
    function ATTRIBUTE_COUNT() external view returns (uint256);

    function registry() external view returns (address);

    function groth16Verifier() external view returns (address);

    /// @notice keccak256(abi.encode("agentbank.proofs.scope.v1", block.chainid, consumer, context)) mod r.
    function scopeOf(address consumer, bytes32 context) external view returns (uint256);

    function nonceUsed(uint256 scope, uint256 nonce) external view returns (bool);

    /// @notice Checks the root (valid, at least `minAnonymitySet` leaves, and when `maxRootAge`
    ///         is non-zero no older than that) and the proof. Returns false on any failure.
    function verify(Claims calldata claims, Groth16Proof calldata proof, uint32 minAnonymitySet, uint64 maxRootAge)
        external
        view
        returns (bool);

    /// @notice For contracts that admit agents: `claims.scope` must equal
    ///         `scopeOf(msg.sender, context)`; the nonce is consumed so the proof cannot be
    ///         replayed. Reverts with the specific error on any failure; returns the nullifier
    ///         (a stable pseudonym of the agent for this consumer and context).
    function verifyAndConsume(
        bytes32 context,
        Claims calldata claims,
        Groth16Proof calldata proof,
        uint32 minAnonymitySet,
        uint64 maxRootAge
    ) external returns (uint256 nullifier);
}
