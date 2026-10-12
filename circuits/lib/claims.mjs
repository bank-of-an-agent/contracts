// Reference implementation of the agentbank.claims.v1 tree, leaf, scope and circuit inputs.
//
// It mirrors agent_claims.circom exactly and is shared by the circuit tests (test/*.test.mjs) and the Foundry
// fixture generator (scripts/fixtures.mjs). It is a test oracle, not the production prover: the SDKs carry their
// own implementation and are checked against the same artifacts.
//
//   identity  = Poseidon1(secret)
//   leaf      = Poseidon2(identity, Poseidon14(attributes[0..12], mask))
//   node      = Poseidon2(left, right); empty subtrees hash from zero leaves: zero[0] = 0, zero[i+1] = Poseidon2(zero[i], zero[i])
//   pathBits  = 1 where the node at that level is a right child
//   nullifier = Poseidon2(secret, scope)
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { keccak_256 } from "@noble/hashes/sha3";
import { poseidon1, poseidon2, poseidon14 } from "poseidon-lite";
import * as snarkjs from "snarkjs";

/** BN254 scalar field order. Every public signal must be below it. */
export const R = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
/** BN254 base field order (proof point coordinates). */
export const Q = 21888242871839275222246405745257275088696311157297823662689037894645226208583n;
export const MAX64 = (1n << 64n) - 1n;
export const DEPTH = 20;

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
export const N_ATTRS = ATTRIBUTES.length;
/** Attribute name -> index. */
export const IDX = Object.fromEntries(ATTRIBUTES.map((name, i) => [name, i]));

/** Disclosure classes (the owner's choice) and the attributes each one unlocks. */
export const CLASSES = {
  principal: ["principal_verification"],
  limits: ["per_tx_limit", "per_day_limit"],
  balance: ["balance"],
  reservations: ["reserved_amount", "reserved_until", "reserved_for"],
  account_age: ["account_created_on"],
  reputation: ["payments_settled", "volume_settled", "escrows_completed", "disputes_lost", "counterparties"],
};
export const FULL_MASK = (1n << BigInt(N_ATTRS)) - 1n;

/** The 13-bit disclosure mask for a set of classes. */
export function maskOf(...classes) {
  let mask = 0n;
  for (const c of classes) {
    if (!CLASSES[c]) throw new Error(`unknown disclosure class ${c}`);
    for (const a of CLASSES[c]) mask |= 1n << BigInt(IDX[a]);
  }
  return mask;
}

const here = (p) => fileURLToPath(new URL(p, import.meta.url));
export const ARTIFACTS = {
  wasm: here("../artifacts/agent_claims.wasm"),
  zkey: here("../artifacts/agent_claims.zkey"),
  vkey: here("../artifacts/verification_key.json"),
};
export const verificationKey = () => JSON.parse(readFileSync(ARTIFACTS.vkey, "utf8"));

// ------------------------------------------------------------------ hashing

export const identityOf = (secret) => poseidon1([secret]);
export const attributeHashOf = (attributes, mask) => poseidon14([...attributes, mask]);
export const leafOf = ({ secret, attributes, mask }) => poseidon2([identityOf(secret), attributeHashOf(attributes, mask)]);
export const nullifierOf = (secret, scope) => poseidon2([secret, scope]);

export const ZEROS = (() => {
  const z = [0n];
  for (let i = 0; i < DEPTH; i++) z.push(poseidon2([z[i], z[i]]));
  return z;
})();

/** A sparse depth-20 Poseidon Merkle tree. `leaves` is an array (dense from index 0) or a Map index -> leaf. */
export class Tree {
  constructor(leaves) {
    const entries = leaves instanceof Map ? [...leaves.entries()] : leaves.map((leaf, i) => [i, leaf]);
    for (const [i] of entries) {
      if (!Number.isInteger(i) || i < 0 || i >= 2 ** DEPTH) throw new Error(`leaf index ${i} out of range`);
    }
    this.leafCount = entries.length;
    this.levels = [new Map(entries)];
    for (let level = 0; level < DEPTH; level++) {
      const nodes = this.levels[level];
      const parents = new Map();
      for (const index of nodes.keys()) {
        const parent = index >> 1;
        if (parents.has(parent)) continue;
        const left = nodes.get(parent * 2) ?? ZEROS[level];
        const right = nodes.get(parent * 2 + 1) ?? ZEROS[level];
        parents.set(parent, poseidon2([left, right]));
      }
      this.levels.push(parents);
    }
    this.root = this.levels[DEPTH].get(0) ?? ZEROS[DEPTH];
  }

  /** Merkle path of the leaf at `index`: siblings bottom-up and pathBits (1 = node is a right child). */
  path(index) {
    const siblings = [];
    const pathBits = [];
    let i = index;
    for (let level = 0; level < DEPTH; level++) {
      siblings.push(this.levels[level].get(i ^ 1) ?? ZEROS[level]);
      pathBits.push(BigInt(i & 1));
      i >>= 1;
    }
    return { siblings, pathBits };
  }
}

// ------------------------------------------------------------------ scopes

const hexToBigInt = (bytes) => BigInt(`0x${Buffer.from(bytes).toString("hex")}`);
const word = (value) => BigInt(value).toString(16).padStart(64, "0");

/** HTTP verifier scope: keccak256(utf8("agentbank.proofs.scope.v1:" + scopeId)) mod r. */
export function httpScope(scopeId) {
  return hexToBigInt(keccak_256(new TextEncoder().encode(`agentbank.proofs.scope.v1:${scopeId}`))) % R;
}

/** On-chain scope: keccak256(abi.encode("agentbank.proofs.scope.v1", chainId, consumer, context)) mod r. */
export function onchainScope(chainId, consumer, context) {
  const domain = Buffer.from("agentbank.proofs.scope.v1", "utf8");
  const encoded =
    word(0x80) + // offset of the dynamic string (four head words)
    word(chainId) +
    word(BigInt(consumer)) +
    word(BigInt(context)) +
    word(domain.length) +
    domain.toString("hex").padEnd(Math.ceil(domain.length / 32) * 64, "0");
  return hexToBigInt(keccak_256(Buffer.from(encoded, "hex"))) % R;
}

/** The reservation tag of a scope: its low 64 bits. */
export const tagOf = (scope) => scope & MAX64;

/** keccak256 of a UTF-8 label as a 0x-prefixed hex string (bytes32 test constants). */
export const keccakHex = (label) => `0x${Buffer.from(keccak_256(new TextEncoder().encode(label))).toString("hex")}`;

// ------------------------------------------------------------------ inputs

/** Bounds from a partial map { attribute: [min, max] }; omitted attributes and undefined ends are unconstrained. */
export function bounds(constraints = {}) {
  const mins = Array(N_ATTRS).fill(0n);
  const maxs = Array(N_ATTRS).fill(MAX64);
  for (const [name, [min, max]] of Object.entries(constraints)) {
    if (!(name in IDX)) throw new Error(`unknown attribute ${name}`);
    if (min !== undefined) mins[IDX[name]] = BigInt(min);
    if (max !== undefined) maxs[IDX[name]] = BigInt(max);
  }
  return { mins, maxs };
}

/** Attributes array from a partial map { attribute: value } (others 0). */
export function attributesOf(values) {
  const attributes = Array(N_ATTRS).fill(0n);
  for (const [name, value] of Object.entries(values)) {
    if (!(name in IDX)) throw new Error(`unknown attribute ${name}`);
    attributes[IDX[name]] = BigInt(value);
  }
  return attributes;
}

/** The circuit's input object. `path` defaults to the tree's path for `index`. */
export function circuitInput({ agent, tree, index, scope, nonce, mins, maxs, path, root }) {
  const { siblings, pathBits } = path ?? tree.path(index);
  return {
    secret: agent.secret,
    attributes: agent.attributes,
    disclosureMask: agent.mask,
    siblings,
    pathBits,
    root: root ?? tree.root,
    scope,
    nonce,
    mins,
    maxs,
  };
}

/** Public signals in circuit order: nullifier, root, scope, nonce, mins[13], maxs[13]. */
export const publicSignalsOf = ({ nullifier, root, scope, nonce, mins, maxs }) =>
  [nullifier, root, scope, nonce, ...mins, ...maxs].map((v) => BigInt(v).toString());

// ------------------------------------------------------------------ proving

/** Runs the witness generator. Throws when any constraint fails. Returns the witness (wire 1 is the nullifier). */
export async function witness(input) {
  const out = { type: "mem" };
  await snarkjs.wtns.calculate(input, ARTIFACTS.wasm, out);
  return (await snarkjs.wtns.exportJson(out)).map(BigInt);
}

/**
 * Runs the witness generator and returns its error message (for example "Assert Failed. Error in template
 * AgentClaims_219 line: 125"), or null when every constraint holds. The runtime's console output is silenced.
 */
export async function witnessError(input) {
  const { log, error } = console;
  console.log = console.error = () => {};
  try {
    await witness(input);
    return null;
  } catch (e) {
    return String(e?.message ?? e);
  } finally {
    console.log = log;
    console.error = error;
  }
}

export const prove = (input) => snarkjs.groth16.fullProve(input, ARTIFACTS.wasm, ARTIFACTS.zkey);

export const verify = (vkey, publicSignals, proof) => snarkjs.groth16.verify(vkey, publicSignals, proof);

/** The proof in AgentClaimsGroth16Verifier calldata order (snarkjs exportSolidityCallData: b pairs swapped). */
export async function solidityCalldata(proof, publicSignals) {
  const [a, b, c, signals] = JSON.parse(`[${await snarkjs.groth16.exportSolidityCallData(proof, publicSignals)}]`);
  return { a, b, c, signals };
}

/** Stops snarkjs' worker threads so the process can exit. */
export async function shutdown() {
  if (globalThis.curve_bn128) await globalThis.curve_bn128.terminate();
}
