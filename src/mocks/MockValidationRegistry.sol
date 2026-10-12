// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC8004ValidationRegistry} from "../interfaces/IERC8004ValidationRegistry.sol";

/// @title MockValidationRegistry
/// @notice TEST/ANVIL ONLY. Mirrors the ERC-8004 Validation Registry v2.0.0 request/response semantics (one validator
///         per request hash, fixed at request time; only that validator responds; responses 0..100, updatable;
///         `lastUpdate` set on request and on every response; unknown hashes revert "unknown").
///         Simplification: there is no Identity Registry, so anyone may open a request for any agent id.
contract MockValidationRegistry is IERC8004ValidationRegistry {
    struct ValidationStatus {
        address validatorAddress;
        uint256 agentId;
        uint8 response;
        bytes32 responseHash;
        string tag;
        uint256 lastUpdate;
        bool hasResponse;
    }

    mapping(bytes32 requestHash => ValidationStatus) private _validations;

    /// @notice A validation was requested.
    event ValidationRequest(
        address indexed validatorAddress, uint256 indexed agentId, string requestURI, bytes32 indexed requestHash
    );
    /// @notice A validator responded.
    event ValidationResponse(
        address indexed validatorAddress,
        uint256 indexed agentId,
        bytes32 indexed requestHash,
        uint8 response,
        string responseURI,
        bytes32 responseHash,
        string tag
    );

    /// @notice Opens a validation request answered only by `validatorAddress`.
    /// @param validatorAddress Validator that may respond.
    /// @param agentId Agent the request is about.
    /// @param requestURI Off-chain request payload location.
    /// @param requestHash Commitment to the request payload; usable once.
    function validationRequest(
        address validatorAddress,
        uint256 agentId,
        string calldata requestURI,
        bytes32 requestHash
    ) external {
        require(validatorAddress != address(0), "bad validator");
        require(_validations[requestHash].validatorAddress == address(0), "exists");
        _validations[requestHash] = ValidationStatus({
            validatorAddress: validatorAddress,
            agentId: agentId,
            response: 0,
            responseHash: bytes32(0),
            tag: "",
            lastUpdate: block.timestamp,
            hasResponse: false
        });
        emit ValidationRequest(validatorAddress, agentId, requestURI, requestHash);
    }

    /// @notice Records (or updates) the validator's response.
    /// @param requestHash Request being answered.
    /// @param response 0 (failed) .. 100 (passed).
    /// @param responseURI Off-chain response payload location.
    /// @param responseHash Commitment to the response payload.
    /// @param tag Free-form tag.
    function validationResponse(
        bytes32 requestHash,
        uint8 response,
        string calldata responseURI,
        bytes32 responseHash,
        string calldata tag
    ) external {
        ValidationStatus storage s = _validations[requestHash];
        require(s.validatorAddress != address(0), "unknown");
        require(msg.sender == s.validatorAddress, "not validator");
        require(response <= 100, "resp>100");
        s.response = response;
        s.responseHash = responseHash;
        s.tag = tag;
        s.lastUpdate = block.timestamp;
        s.hasResponse = true;
        emit ValidationResponse(s.validatorAddress, s.agentId, requestHash, response, responseURI, responseHash, tag);
    }

    /// @inheritdoc IERC8004ValidationRegistry
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
        )
    {
        ValidationStatus memory s = _validations[requestHash];
        require(s.validatorAddress != address(0), "unknown");
        return (s.validatorAddress, s.agentId, s.response, s.responseHash, s.tag, s.lastUpdate);
    }
}
