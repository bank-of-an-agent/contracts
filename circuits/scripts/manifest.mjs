// Writes artifacts/manifest.json: what the artifacts are, how they were made and their hashes.
// Consumers (the agent-bank monorepo, the Python SDK) pin the manifest, not the files directly.
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import * as snarkjs from "snarkjs";

const sha256 = (path) => createHash("sha256").update(readFileSync(path)).digest("hex");

export const ATTRIBUTES = [
  "principal_verification",
  "per_tx_limit",
  "per_day_limit",
  "balance",
  "reserved_amount",
  "reserved_until",
  "reserved_for",
  "account_created_on",
  "payments_settled",
  "volume_settled",
  "escrows_completed",
  "disputes_lost",
  "counterparties",
];

const info = await snarkjs.r1cs.info("build/agent_claims.r1cs");
const vkey = JSON.parse(readFileSync("artifacts/verification_key.json", "utf8"));

const manifest = {
  schema: "agentbank.claims.v1",
  circuit: "circuits/agent_claims.circom",
  protocol: "groth16",
  curve: "bn128",
  tree_depth: 20,
  attributes: ATTRIBUTES,
  public_signals: [
    "nullifier",
    "root",
    "scope",
    "nonce",
    ...ATTRIBUTES.map((a) => `min.${a}`),
    ...ATTRIBUTES.map((a) => `max.${a}`),
  ],
  constraints: info.nConstraints,
  toolchain: { circom: "2.2.3", circomlib: "2.0.5", snarkjs: "0.7.6" },
  ceremony: "testnet-only single-party setup; see ceremony/TRANSCRIPT.md",
  sha256: {
    r1cs: sha256("build/agent_claims.r1cs"),
    wasm: sha256("artifacts/agent_claims.wasm"),
    zkey: sha256("artifacts/agent_claims.zkey"),
    verification_key: sha256("artifacts/verification_key.json"),
    solidity_verifier: sha256("../src/verifiers/AgentClaimsGroth16Verifier.sol"),
  },
};

if (vkey.nPublic !== manifest.public_signals.length) {
  throw new Error(`verification key has ${vkey.nPublic} public signals, layout has ${manifest.public_signals.length}`);
}
writeFileSync("artifacts/manifest.json", `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`manifest: ${manifest.constraints} constraints, ${vkey.nPublic} public signals`);
process.exit(0);
