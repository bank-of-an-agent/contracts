// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {AgentClaimsGroth16Verifier} from "../../src/verifiers/AgentClaimsGroth16Verifier.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {ClaimsFixtures} from "../utils/ClaimsFixtures.sol";

/// @notice The generated snarkjs verifier on its own (AgentClaimsVerifier adds the registry and range checks on top).
contract AgentClaimsGroth16VerifierTest is BaseTest, ClaimsFixtures {
    AgentClaimsGroth16Verifier internal groth16;
    Fixture internal company;

    function setUp() public override {
        super.setUp();
        groth16 = new AgentClaimsGroth16Verifier();
        company = _fixture("verified_company");
    }

    function _call(uint256[30] memory signals, uint256 gas) internal view returns (bool ok, bool valid) {
        bytes memory data = abi.encodeCall(
            AgentClaimsGroth16Verifier.verifyProof, (company.proof.a, company.proof.b, company.proof.c, signals)
        );
        bytes memory ret;
        (ok, ret) = address(groth16).staticcall{gas: gas}(data);
        if (ok && ret.length == 32) valid = abi.decode(ret, (bool));
    }

    function test_acceptsTheFixtureProof() public view {
        (bool ok, bool valid) = _call(_signals(company.claims), 1_000_000);
        assertTrue(ok);
        assertTrue(valid);
    }

    /// @notice A public signal at or above the field order is refused even when it equals the proven one mod r.
    function test_rejectsNonCanonicalSignals() public view {
        for (uint256 i; i < 30; ++i) {
            uint256[30] memory s = _signals(company.claims);
            s[i] += SNARK_SCALAR_FIELD;
            (bool ok, bool valid) = _call(s, 1_000_000);
            assertTrue(ok, "returns, never reverts");
            assertFalse(valid, vm.toString(i));
        }
    }

    /// @notice Running out of gas anywhere (scalar multiplications, additions or the pairing) never yields `true`:
    ///         the verifier returns false (a precompile failed) or the call fails.
    function test_tooLittleGasNeverVerifies() public view {
        uint256[30] memory s = _signals(company.claims);
        uint256 needed; // the first gas limit that verifies; every larger one must verify too
        for (uint256 gas = 1000; gas <= 600_000; gas += 997) {
            (, bool valid) = _call(s, gas);
            if (valid && needed == 0) needed = gas;
            if (!valid) assertEq(needed, 0, vm.toString(gas));
        }
        assertGt(needed, 300_000, "a valid proof needs the full pairing");
    }
}
