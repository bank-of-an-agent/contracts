# ADR 0003: Private proofs use a Circom/Groth16 claims circuit and an on-chain root registry

- **Status:** Accepted (Base Sepolia only)
- **Date:** 2026-10-12
- **Deciders:** Agent Bank core team
- **Design:** `agent-bank/docs/private-proofs.md`; platform decision in `agent-bank` ADR 0014

## Context

Agents need to prove facts Agent Bank attests about them (a verified backer, spending limits,
balance, reserved funds, reputation) without revealing which agent they are. The proof must
verify cheaply both off-chain (SDKs) and on-chain (contracts that admit agents), on Base.

## Decision

1. **Circuit:** `circuits/agent_claims.circom`, written in Circom 2.2.3 with circomlib 2.0.5:
   Poseidon leaf and Merkle inclusion (depth 20), 64-bit range checks on 13 attributes, a
   disclosure mask that forces unconstrained bounds on undisclosed attributes, a per-scope
   nullifier, and a bound nonce. 10,270 constraints; 30 public signals.
2. **Proof system:** Groth16 on BN254. Proofs are 256 bytes, verification uses the EVM's BN254
   precompiles (about 390,000 gas with 30 public inputs) and snarkjs proves in about 1.3 s.
   PLONK/fflonk would avoid a circuit-specific setup but cost more gas and prover time; Noir
   with UltraHonk is attractive but its Solidity verifier is far more expensive and its tooling
   downloads parameters at run time.
3. **Trusted setup, testnet:** a single-party ceremony (`circuits/scripts/ceremony.sh`): local
   Powers of Tau 2^14 with one contribution and a beacon, then one phase-2 contribution and a
   beacon. The phase-1 file is committed so CI re-verifies the proving key
   (`circuits/scripts/check.sh`). The transcript is in `circuits/ceremony/TRANSCRIPT.md`.
4. **Trusted setup, mainnet (gate):** phase 1 from a public multi-party Powers of Tau, and a
   multi-party phase 2 with independent contributors, a public transcript and a final beacon.
   The verifier contract is regenerated and redeployed; the registry is unaffected.
5. **Contracts:** `AgentAttestationRegistry` stores roots published by a single attester key
   (rotatable by an `Ownable2Step` admin) with a validity window of at most 7 days and explicit
   revocation. `AgentClaimsVerifier` wraps the generated `AgentClaimsGroth16Verifier`, checks the
   root against the registry and offers a nonce-consuming entry point for on-chain consumers.
   Neither contract holds or moves funds.
6. **Reproducibility:** circom compilation is deterministic; CI recompiles, compares the R1CS and
   WASM hashes in `circuits/artifacts/manifest.json`, verifies the zkey, and re-exports the
   verification key and Solidity verifier byte for byte.

## Consequences

- Whoever ran the testnet ceremony could forge testnet proofs. This is acceptable on Base
  Sepolia only and is listed in `AUDIT_SCOPE.md` as a known limitation.
- The circuit and both contracts join the audit scope; ZK circuits need a specialist reviewer.
- Any change to the circuit requires a new ceremony, new artifacts, a new verifier deployment and
  a new schema version (`agentbank.claims.v2`).
