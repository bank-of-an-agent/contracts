// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IAgentClaimsVerifier} from "../../src/interfaces/IAgentClaimsVerifier.sol";

/// @notice Loads the real claims proofs written by `circuits/scripts/fixtures.mjs` (`npm run fixtures`) from
///         test/fixtures/claims/*.json. All fixtures come from one 5-leaf tree and use the scope
///         `scopeOf(consumer, context)` on Base Sepolia (84532).
abstract contract ClaimsFixtures is Test {
    uint256 internal constant SNARK_SCALAR_FIELD =
        21_888_242_871_839_275_222_246_405_745_257_275_088_548_364_400_416_034_343_698_204_186_575_808_495_617;
    uint64 internal constant MAX64 = type(uint64).max;

    struct Fixture {
        string name;
        uint256 chainId;
        address consumer;
        bytes32 context;
        uint32 leafCount;
        IAgentClaimsVerifier.Claims claims;
        IAgentClaimsVerifier.Groth16Proof proof;
        uint256[] publicSignals;
    }

    function _fixture(string memory name) internal view returns (Fixture memory f) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/claims/", name, ".json"));
        f.name = name;
        f.chainId = vm.parseJsonUint(json, ".chainId");
        f.consumer = vm.parseJsonAddress(json, ".consumer");
        f.context = vm.parseJsonBytes32(json, ".context");
        f.leafCount = uint32(vm.parseJsonUint(json, ".leafCount"));
        f.claims.root = vm.parseJsonBytes32(json, ".root");
        f.claims.nullifier = vm.parseJsonUint(json, ".nullifier");
        f.claims.scope = vm.parseJsonUint(json, ".scope");
        f.claims.nonce = vm.parseJsonUint(json, ".nonce");
        uint256[] memory mins = vm.parseJsonUintArray(json, ".mins");
        uint256[] memory maxs = vm.parseJsonUintArray(json, ".maxs");
        assertEq(mins.length, 13, "mins");
        assertEq(maxs.length, 13, "maxs");
        for (uint256 i; i < 13; ++i) {
            f.claims.mins[i] = uint64(mins[i]);
            f.claims.maxs[i] = uint64(maxs[i]);
        }
        uint256[] memory p = vm.parseJsonUintArray(json, ".proof");
        assertEq(p.length, 8, "proof");
        f.proof.a = [p[0], p[1]];
        f.proof.b = [[p[2], p[3]], [p[4], p[5]]];
        f.proof.c = [p[6], p[7]];
        f.publicSignals = vm.parseJsonUintArray(json, ".publicSignals");
        assertEq(f.publicSignals.length, 30, "publicSignals");
    }

    /// @dev Public signals in circuit order, as the verifier builds them.
    function _signals(IAgentClaimsVerifier.Claims memory c) internal pure returns (uint256[30] memory s) {
        s[0] = c.nullifier;
        s[1] = uint256(c.root);
        s[2] = c.scope;
        s[3] = c.nonce;
        for (uint256 i; i < 13; ++i) {
            s[4 + i] = c.mins[i];
            s[17 + i] = c.maxs[i];
        }
    }
}
