// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IAgentAttestationRegistry} from "./interfaces/IAgentAttestationRegistry.sol";

/// @title AgentAttestationRegistry
/// @author Agent Bank
/// @notice Public, timestamped roots of Agent Bank's attested-facts Merkle trees (schema agentbank.claims.v1).
///         Agent Bank's attester key publishes one root per snapshot; proofs made with `AgentClaimsVerifier` (or the
///         SDKs, off-chain) are only accepted against a root that is published here, not revoked and not expired.
///         Anchoring stops Agent Bank from showing different verifiers different trees.
/// @dev Holds and moves no funds. Two roles:
///      - the attester (a hot key, KMS outside testnet) publishes and revokes roots;
///      - the owner (`Ownable2Step`, a governance multisig) rotates the attester and can revoke roots.
///      Ownership can be transferred but never renounced, so the attester can always be rotated.
///      A root is "published" when its stored epoch is non-zero: every accepted epoch is > latestEpoch >= 0.
contract AgentAttestationRegistry is IAgentAttestationRegistry, Ownable2Step {
    /// @inheritdoc IAgentAttestationRegistry
    uint64 public constant override MAX_VALIDITY = 7 days;

    /// @inheritdoc IAgentAttestationRegistry
    uint256 public constant override SNARK_SCALAR_FIELD =
        21_888_242_871_839_275_222_246_405_745_257_275_088_548_364_400_416_034_343_698_204_186_575_808_495_617;

    /// @notice Ownership cannot be renounced: an ownerless registry could never rotate a compromised attester.
    error RenounceOwnershipDisabled();

    /// @inheritdoc IAgentAttestationRegistry
    address public override attester;

    /// @inheritdoc IAgentAttestationRegistry
    uint64 public override latestEpoch;

    /// @inheritdoc IAgentAttestationRegistry
    bytes32 public override latestRoot;

    mapping(bytes32 root => RootInfo) private _roots;

    /// @param initialOwner Registry owner (governance multisig); rotates the attester and may revoke roots.
    /// @param initialAttester Agent Bank's attester key.
    constructor(address initialOwner, address initialAttester) Ownable(_nonZero(initialOwner)) {
        if (initialAttester == address(0)) revert ZeroAddress();
        attester = initialAttester;
        emit AttesterChanged(address(0), initialAttester);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Attester
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAgentAttestationRegistry
    function publishRoot(bytes32 root, uint64 epoch, uint64 snapshotAt, uint64 validUntil, uint32 leafCount) external {
        if (msg.sender != attester) revert NotAttester(msg.sender);
        if (root == bytes32(0) || uint256(root) >= SNARK_SCALAR_FIELD) revert InvalidRoot(root);
        if (_roots[root].epoch != 0) revert RootAlreadyPublished(root);
        uint64 latest = latestEpoch;
        if (epoch <= latest) revert EpochNotIncreasing(latest, epoch);
        if (snapshotAt > block.timestamp) revert SnapshotInFuture(snapshotAt);
        if (validUntil <= block.timestamp || validUntil > block.timestamp + MAX_VALIDITY) {
            revert InvalidValidity(validUntil);
        }
        if (leafCount == 0) revert EmptyTree();

        _roots[root] = RootInfo({
            epoch: epoch,
            snapshotAt: snapshotAt,
            // forge-lint: disable-next-line(unsafe-typecast)
            publishedAt: uint64(block.timestamp), // uint64 seconds outlast the chain
            validUntil: validUntil,
            leafCount: leafCount,
            revoked: false
        });
        latestEpoch = epoch;
        latestRoot = root;
        emit RootPublished(root, epoch, snapshotAt, validUntil, leafCount);
    }

    /// @inheritdoc IAgentAttestationRegistry
    function revokeRoots(bytes32[] calldata roots) external {
        if (msg.sender != attester && msg.sender != owner()) revert NotAttesterOrOwner(msg.sender);
        for (uint256 i; i < roots.length; ++i) {
            bytes32 root = roots[i];
            RootInfo storage info = _roots[root];
            if (info.epoch == 0) revert UnknownRoot(root);
            if (info.revoked) continue;
            info.revoked = true;
            emit RootRevoked(root, msg.sender);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Owner
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAgentAttestationRegistry
    function setAttester(address newAttester) external onlyOwner {
        if (newAttester == address(0)) revert ZeroAddress();
        address previous = attester;
        attester = newAttester;
        emit AttesterChanged(previous, newAttester);
    }

    /// @notice Always reverts: the registry must keep an owner able to rotate the attester.
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAgentAttestationRegistry
    function rootInfo(bytes32 root) external view returns (RootInfo memory) {
        return _roots[root];
    }

    /// @inheritdoc IAgentAttestationRegistry
    function isValidRoot(bytes32 root) external view returns (bool) {
        RootInfo storage info = _roots[root];
        return info.epoch != 0 && !info.revoked && block.timestamp <= info.validUntil;
    }

    /// @dev Lets the constructor reject a zero owner with `ZeroAddress` before `Ownable` would.
    function _nonZero(address account) private pure returns (address) {
        if (account == address(0)) revert ZeroAddress();
        return account;
    }
}
