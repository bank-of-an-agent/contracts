// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @title IAgentAttestationRegistry
/// @notice Roots of Agent Bank's attested-facts Merkle trees (schema agentbank.claims.v1).
/// @dev Agent Bank's attester key publishes one root per snapshot. A root is valid from
///      publication until `validUntil` unless revoked. The registry holds and moves no funds.
interface IAgentAttestationRegistry {
    /// @notice What the registry records about a published root.
    /// @param epoch Strictly increasing snapshot number.
    /// @param snapshotAt Unix time the attested facts were read.
    /// @param publishedAt Block timestamp of publication.
    /// @param validUntil Unix time after which proofs against this root are refused.
    /// @param leafCount Number of leaves: the anonymity set of proofs against this root.
    /// @param revoked Whether the attester or owner revoked the root early.
    struct RootInfo {
        uint64 epoch;
        uint64 snapshotAt;
        uint64 publishedAt;
        uint64 validUntil;
        uint32 leafCount;
        bool revoked;
    }

    event RootPublished(
        bytes32 indexed root, uint64 indexed epoch, uint64 snapshotAt, uint64 validUntil, uint32 leafCount
    );
    event RootRevoked(bytes32 indexed root, address indexed by);
    event AttesterChanged(address indexed previousAttester, address indexed newAttester);

    error NotAttester(address caller);
    error NotAttesterOrOwner(address caller);
    error InvalidRoot(bytes32 root);
    error RootAlreadyPublished(bytes32 root);
    error UnknownRoot(bytes32 root);
    error EpochNotIncreasing(uint64 latestEpoch, uint64 epoch);
    error SnapshotInFuture(uint64 snapshotAt);
    error InvalidValidity(uint64 validUntil);
    error EmptyTree();
    error ZeroAddress();

    /// @notice Longest validity window a root may have, measured from publication (7 days).
    function MAX_VALIDITY() external view returns (uint64);

    /// @notice The BN254 scalar field order; roots must be field elements.
    function SNARK_SCALAR_FIELD() external view returns (uint256);

    function attester() external view returns (address);

    function latestEpoch() external view returns (uint64);

    function latestRoot() external view returns (bytes32);

    function rootInfo(bytes32 root) external view returns (RootInfo memory);

    /// @notice Published, not revoked and `block.timestamp <= validUntil`.
    function isValidRoot(bytes32 root) external view returns (bool);

    /// @notice Attester only. Requires a non-zero root below the field order that was never
    ///         published, `epoch > latestEpoch()`, `snapshotAt <= block.timestamp`,
    ///         `block.timestamp < validUntil <= block.timestamp + MAX_VALIDITY` and `leafCount > 0`.
    function publishRoot(bytes32 root, uint64 epoch, uint64 snapshotAt, uint64 validUntil, uint32 leafCount) external;

    /// @notice Attester or owner. Revokes each published root; already-revoked roots are skipped.
    ///         Reverts with `UnknownRoot` for a root that was never published.
    function revokeRoots(bytes32[] calldata roots) external;

    /// @notice Owner only. Rotates the attester key.
    function setAttester(address newAttester) external;
}
