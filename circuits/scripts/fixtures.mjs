// Writes real claims proofs for the Foundry tests to ../test/fixtures/claims/*.json (npm run fixtures).
//
// All fixtures come from one 5-leaf tree and use the on-chain scope of CONSUMER and CONTEXT on Base Sepolia, so
// AgentClaimsVerifier.verifyAndConsume accepts them when CONSUMER calls it on chain 84532. Groth16 proving is
// randomized: re-running changes the proof bytes, never the statements. Every number is a 0x-prefixed hex string
// except chainId, leafCount and index; `proof` is in AgentClaimsGroth16Verifier calldata order
// [a0, a1, b00, b01, b10, b11, c0, c1] (snarkjs exportSolidityCallData: each b pair swapped).
import { mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import * as C from "../lib/claims.mjs";

const OUT = fileURLToPath(new URL("../../test/fixtures/claims/", import.meta.url));
const CHAIN_ID = 84532;
const CONSUMER = "0x00000000000000000000000000000000000a11ce";
const CONTEXT = C.keccakHex("agentbank.fixtures.admission");
const SCOPE = C.onchainScope(CHAIN_ID, CONSUMER, CONTEXT);
const NOW = 1_760_000_000n;
const DAY = 86_400n;

const company = {
  secret: BigInt(C.keccakHex("fixture.company.secret")) % C.R,
  attributes: C.attributesOf({
    principal_verification: 2,
    per_tx_limit: 10_000000,
    per_day_limit: 250_000000,
    balance: 1_500_000000,
    account_created_on: NOW - 120n * DAY,
    payments_settled: 42,
    volume_settled: 900_000000,
    counterparties: 7,
  }),
  mask: C.maskOf("principal", "limits", "balance"),
};
const saver = {
  secret: BigInt(C.keccakHex("fixture.saver.secret")) % C.R,
  attributes: C.attributesOf({
    principal_verification: 1,
    balance: 3_000_000000,
    reserved_amount: 750_000000,
    reserved_until: NOW + 3n * DAY,
    reserved_for: C.tagOf(SCOPE),
    account_created_on: NOW - 10n * DAY,
  }),
  mask: C.maskOf("balance", "reservations"),
};
const filler = (label) => ({
  secret: BigInt(C.keccakHex(label)) % C.R,
  attributes: C.attributesOf({ principal_verification: 1, balance: 5_000000 }),
  mask: 0n,
});
const members = [filler("fixture.filler.0"), company, filler("fixture.filler.2"), saver, filler("fixture.filler.4")];
const tree = new C.Tree(members.map(C.leafOf));

const fixtures = {
  unconstrained: {
    description: "All bounds [0, 2^64 - 1]: proves only membership in the tree",
    index: 0,
    nonce: BigInt(C.keccakHex("fixture.nonce.unconstrained")) >> 8n,
    ...C.bounds(),
  },
  verified_company: {
    description: "verifiedCompany() and canPayPerTx(5.00) and spendingCappedAt({ perDay: 1000.00 })",
    index: 1,
    nonce: BigInt(C.keccakHex("fixture.nonce.verified_company")) >> 8n,
    ...C.bounds({ principal_verification: [2, 2], per_tx_limit: [5_000000], per_day_limit: [, 1_000_000000] }),
  },
  reservation: {
    description: "reservedFor(500.00, { until: NOW + 1 day }) for this consumer's scope",
    index: 3,
    nonce: BigInt(C.keccakHex("fixture.nonce.reservation")) >> 8n,
    ...C.bounds({
      reserved_amount: [500_000000],
      reserved_until: [NOW + DAY],
      reserved_for: [C.tagOf(SCOPE), C.tagOf(SCOPE)],
    }),
  },
};

const hex = (v) => `0x${BigInt(v).toString(16).padStart(64, "0")}`;
const vkey = C.verificationKey();
mkdirSync(OUT, { recursive: true });

for (const [name, f] of Object.entries(fixtures)) {
  const agent = members[f.index];
  const input = C.circuitInput({ agent, tree, index: f.index, scope: SCOPE, nonce: f.nonce, mins: f.mins, maxs: f.maxs });
  const { proof, publicSignals } = await C.prove(input);
  if (!(await C.verify(vkey, publicSignals, proof))) throw new Error(`${name}: proof does not verify`);
  const nullifier = C.nullifierOf(agent.secret, SCOPE);
  if (publicSignals[0] !== nullifier.toString()) throw new Error(`${name}: unexpected nullifier`);
  const { a, b, c, signals } = await C.solidityCalldata(proof, publicSignals);
  const fixture = {
    name,
    description: f.description,
    chainId: CHAIN_ID,
    consumer: CONSUMER,
    context: CONTEXT,
    root: hex(tree.root),
    leafCount: tree.leafCount,
    index: f.index,
    nullifier: hex(nullifier),
    scope: hex(SCOPE),
    nonce: hex(f.nonce),
    mins: f.mins.map(hex),
    maxs: f.maxs.map(hex),
    proof: [...a, ...b[0], ...b[1], ...c],
    publicSignals: signals,
  };
  writeFileSync(`${OUT}${name}.json`, `${JSON.stringify(fixture, null, 2)}\n`);
  console.log(`wrote test/fixtures/claims/${name}.json`);
}
await C.shutdown();
