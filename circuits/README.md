# Claims circuit

The zero-knowledge circuit behind Agent Bank's private proofs (schema `agentbank.claims.v1`). An
agent proves that Agent Bank attested facts about it, such as a verified backer, spending limits,
balance, funds reserved for this verifier or a track record, without revealing which agent it is
or the underlying values.

> [!WARNING]
> The proving and verification keys come from a **single-party, testnet-only** trusted setup.
> Whoever ran it could forge proofs. Mainnet needs a public multi-party ceremony
> ([ADR 0003](../docs/adr/0003-private-proofs.md)) and a circuit audit.

## What it proves

[`agent_claims.circom`](agent_claims.circom), Circom 2.2.3, Groth16 on BN254, 10,270 constraints:

- the agent knows `secret` such that `Poseidon(Poseidon(secret), Poseidon(attributes, mask))` is a
  leaf of the depth-20 Poseidon Merkle tree whose root is public;
- each of the 13 attributes lies within the verifier's public `[min, max]` (64-bit range checks);
- attributes the owner did not disclose (mask bit clear) carry only the trivial bound
  `[0, 2^64 − 1]`;
- `nullifier = Poseidon(secret, scope)`: stable for one verifier, unlinkable across verifiers;
- the verifier's `nonce` is bound into the proof.

Public signals, in order: `nullifier, root, scope, nonce, mins[13], maxs[13]`. The attribute list
and the full design are in the circuit header and in
[`agent-bank/docs/private-proofs.md`](https://github.com/bank-of-an-agent/agent-bank/blob/main/docs/private-proofs.md).

## Usage

Needs Node.js 22 and circom 2.2.3 (`nix shell github:NixOS/nixpkgs/6510408d147d8c5e6d76043e899e9251756f6a75#circom`).

```bash
npm ci
scripts/check.sh      # recompile; R1CS/WASM hashes, zkey verification, byte-identical exports
npm test              # completeness, soundness, disclosure and binding tests with real proofs
npm run fixtures      # regenerate ../test/fixtures/claims/*.json for the Foundry tests
```

| Script                 | Does                                                                                    |
| ---------------------- | --------------------------------------------------------------------------------------- |
| `scripts/build.sh`     | Compiles to `build/` (deterministic: same circom, same bytes)                            |
| `scripts/ceremony.sh`  | Testnet-only setup: new phase 1 and phase 2, then `export.sh` and the transcript         |
| `scripts/export.sh`    | Derives the verification key, the Solidity verifier, the WASM copy and `manifest.json`   |
| `scripts/check.sh`     | What CI runs: proves the committed artifacts come from the committed circuit             |

## What's here

```
agent_claims.circom      the circuit
artifacts/               agent_claims.wasm, agent_claims.zkey, verification_key.json, manifest.json
ceremony/                pot14_final.ptau (phase 1, kept so CI can verify the zkey) and TRANSCRIPT.md
lib/claims.mjs           reference tree and leaf construction shared by tests and fixtures
scripts/                 build, ceremony, export, check, manifest, fixtures
test/                    node:test suites
```

`manifest.json` records the schema, attribute order, public-signal layout, toolchain versions and
the SHA-256 of every artifact. Consumers pin the manifest: the monorepo's `@agentbank/proofs`
copies `artifacts/` with `pnpm --filter @agentbank/proofs sync-circuits`, which checks every hash,
and the Python SDK bundles the verification key.

## Changing the circuit

Any change to `agent_claims.circom` changes the R1CS, so CI fails until you run a new ceremony,
regenerate fixtures, redeploy `AgentClaimsGroth16Verifier` and `AgentClaimsVerifier`, and bump the
schema (`agentbank.claims.v2`). Never edit `artifacts/` or `../src/verifiers/` by hand.
