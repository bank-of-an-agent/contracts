// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @title Minimal ERC-8004 Validation Registry read interface
/// @notice Matches `ValidationRegistryUpgradeable` v2.0.0 from https://github.com/erc-8004/erc-8004-contracts and the
///         ERC-8004 draft (https://eips.ethereum.org/EIPS/eip-8004). Deployed on Base Sepolia at
///         0x8004Cb1BF31DAf7788923b405b754f57acEB4272 (UUPS proxy).
/// @dev Registry semantics this repository relies on (verified against the reference implementation):
///      - a `requestHash` can be requested only once and is bound to one `validatorAddress` at request time;
///      - only that validator can respond; responses are 0..100 and may be updated (last write wins);
///      - `lastUpdate` is set on request *and* on every response, and there is no public "has responded" flag,
///        so a threshold of 0 would be satisfied by a request that was never answered;
///      - `getValidationStatus` reverts ("unknown") for a hash that was never requested.
interface IERC8004ValidationRegistry {
    /// @notice Current validation status for `requestHash`.
    /// @param requestHash Commitment to the validation request payload.
    /// @return validatorAddress Validator chosen at request time.
    /// @return agentId ERC-8004 agent id the request is about.
    /// @return response Latest response, 0 (failed) .. 100 (passed).
    /// @return responseHash Commitment to the response payload.
    /// @return tag Free-form response tag.
    /// @return lastUpdate Timestamp of the request or of the latest response.
    function getValidationStatus(bytes32 requestHash)
        external
        view
        returns (
            address validatorAddress,
            uint256 agentId,
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        );
}
