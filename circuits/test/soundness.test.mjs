// Soundness: statements that are false, or that the owner did not allow, cannot be witnessed.
//
// Every case runs the circuit's witness generator, which checks each constraint, and asserts on the exact
// constraint that rejects it (agent_claims.circom line numbers; the circuit is frozen by the ceremony):
//   56  pathBits[i] is boolean (MerkleInclusion)       118/120  mins/maxs fit in 64 bits (Num2Bits)
//   103 the leaf is in the tree with this root           125/130  min <= attribute <= max
//   106 the mask fits in 13 bits (Num2Bits)              133/134  undisclosed attributes have bounds [0, 2^64 - 1]
//   116 every attribute fits in 64 bits (Num2Bits)
import assert from "node:assert/strict";
import { after, describe, test } from "node:test";

import * as C from "../lib/claims.mjs";

after(C.shutdown);

const SCOPE = C.httpScope("api.seller.example");
const NONCE = BigInt(C.keccakHex("soundness nonce")) >> 8n; // 31 bytes, like a verifier's nonce
const LINE = {
  pathBit: /MerkleInclusion_\d+ line: 56/,
  inTree: /AgentClaims_\d+ line: 103$/m,
  maskBits: /Num2Bits_\d+ line: \d+\s+Error in template AgentClaims_\d+ line: 106/,
  attributeBits: /Num2Bits_\d+ line: \d+\s+Error in template AgentClaims_\d+ line: 116/,
  minBits: /Num2Bits_\d+ line: \d+\s+Error in template AgentClaims_\d+ line: 118/,
  maxBits: /Num2Bits_\d+ line: \d+\s+Error in template AgentClaims_\d+ line: 120/,
  min: /AgentClaims_\d+ line: 125/,
  max: /AgentClaims_\d+ line: 130/,
  undisclosedMin: /AgentClaims_\d+ line: 133/,
  undisclosedMax: /AgentClaims_\d+ line: 134/,
};

// Every attribute strictly inside (0, 2^64 - 1) so each can sit just below a min or just above a max.
const agent = {
  secret: 0x0a9e_17n * 1_000_003n,
  attributes: C.attributesOf({
    principal_verification: 2,
    per_tx_limit: 25_000000,
    per_day_limit: 500_000000,
    balance: 1_234_000000,
    reserved_amount: 500_000000,
    reserved_until: 1_760_086_400,
    reserved_for: C.tagOf(SCOPE),
    account_created_on: 1_700_006_400,
    payments_settled: 321,
    volume_settled: 4_567_000000,
    escrows_completed: 12,
    disputes_lost: 1,
    counterparties: 37,
  }),
  mask: C.FULL_MASK,
};
const others = [101n, 202n, 303n].map((secret) => ({ secret, attributes: C.attributesOf({}), mask: 0n }));
const INDEX = 2;
const tree = new C.Tree([C.leafOf(others[0]), C.leafOf(others[1]), C.leafOf(agent), C.leafOf(others[2])]);

const input = (overrides = {}, who = agent, inTree = tree, index = INDEX) => ({
  ...C.circuitInput({ agent: who, tree: inTree, index, scope: SCOPE, nonce: NONCE, ...C.bounds() }),
  ...overrides,
});
const withAt = (array, i, value) => array.map((v, j) => (j === i ? value : v));
const ok = async (inp, msg) => assert.equal(await C.witnessError(inp), null, msg);
const fails = async (inp, pattern, msg) => {
  const err = await C.witnessError(inp);
  assert.ok(err, `${msg}: expected witness generation to fail`);
  assert.match(err, pattern, msg);
};
const unconstrained = C.bounds();

describe("bounds", () => {
  test("bounds equal to the attribute values (exact equality on all 13) are satisfiable", async () => {
    await ok(input({ mins: agent.attributes, maxs: agent.attributes }));
  });

  for (const [i, name] of C.ATTRIBUTES.entries()) {
    test(`${name}: just below min and just above max both fail`, async () => {
      const value = agent.attributes[i];
      await fails(input({ mins: withAt(unconstrained.mins, i, value + 1n) }), LINE.min, `${name} = min - 1`);
      await fails(input({ maxs: withAt(unconstrained.maxs, i, value - 1n) }), LINE.max, `${name} = max + 1`);
    });
  }

  test("bounds of 2^64 or more are rejected on every attribute, even when they would hold", async () => {
    for (const [i, name] of C.ATTRIBUTES.entries()) {
      await fails(input({ maxs: withAt(unconstrained.maxs, i, 1n << 64n) }), LINE.maxBits, `${name} max = 2^64`);
      await fails(input({ mins: withAt(unconstrained.mins, i, 1n << 64n) }), LINE.minBits, `${name} min = 2^64`);
    }
    // A "negative" min (r - 1) would make min <= attribute vacuous if the comparator saw it as a field element.
    await fails(input({ mins: withAt(unconstrained.mins, 3, C.R - 1n) }), LINE.minBits, "min = -1 mod r");
    await fails(input({ maxs: withAt(unconstrained.maxs, 3, C.R - 1n) }), LINE.maxBits, "max = -1 mod r");
  });

  test("boundary values 0 and 2^64 - 1 are accepted", async () => {
    const edge = { ...agent, attributes: withAt(withAt(agent.attributes, 3, 0n), 1, C.MAX64) };
    const edgeTree = new C.Tree([C.leafOf(edge)]);
    await ok(input({ mins: edge.attributes, maxs: edge.attributes }, edge, edgeTree, 0));
  });

  test("an attester leaf with an attribute of 2^64 or more can never be proven", async () => {
    for (const bad of [1n << 64n, C.R - 1n]) {
      const rogue = { ...agent, attributes: withAt(agent.attributes, 3, bad) };
      const rogueTree = new C.Tree([C.leafOf(rogue)]);
      await fails(input({}, rogue, rogueTree, 0), LINE.attributeBits, `balance = ${bad}`);
    }
  });
});

describe("disclosure mask", () => {
  for (const [i, name] of C.ATTRIBUTES.entries()) {
    test(`${name}: undisclosed means not even a trivial bound`, async () => {
      const hidden = { ...agent, mask: C.FULL_MASK ^ (1n << BigInt(i)) };
      const hiddenTree = new C.Tree([C.leafOf(hidden)]);
      const at = (o) => input(o, hidden, hiddenTree, 0);
      await ok(at({}), "unconstrained bounds are always allowed");
      await fails(at({ mins: withAt(unconstrained.mins, i, 1n) }), LINE.undisclosedMin, `${name} min = 1`);
      await fails(at({ maxs: withAt(unconstrained.maxs, i, C.MAX64 - 1n) }), LINE.undisclosedMax, `${name} max < 2^64-1`);
      // The same trivial bounds hold for the fully disclosed leaf.
      await ok(input({ mins: withAt(unconstrained.mins, i, 1n), maxs: withAt(unconstrained.maxs, i, C.MAX64 - 1n) }));
    });
  }

  test("an owner's class selection limits what can be asked", async () => {
    const limited = { ...agent, mask: C.maskOf("principal", "limits") };
    const limitedTree = new C.Tree([C.leafOf(limited)]);
    const at = (constraints) => input(C.bounds(constraints), limited, limitedTree, 0);
    await ok(at({ principal_verification: [2, 2], per_tx_limit: [5_000000], per_day_limit: [, 1_000_000000] }));
    await fails(at({ balance: [1_000_000000] }), LINE.undisclosedMin, "balance is not disclosed");
    await fails(at({ disputes_lost: [, 5] }), LINE.undisclosedMax, "reputation is not disclosed (1 <= 5 holds)");
  });

  test("a mask of 2^13 or more in a leaf can never be proven", async () => {
    const rogue = { ...agent, mask: 1n << 13n };
    const rogueTree = new C.Tree([C.leafOf(rogue)]);
    await fails(input({}, rogue, rogueTree, 0), LINE.maskBits, "mask = 2^13");
  });

  test("a different mask than the attested one is not in the tree", async () => {
    await fails(input({ disclosureMask: C.maskOf("principal") }), LINE.inTree, "mask changed");
  });
});

describe("membership", () => {
  const { siblings, pathBits } = tree.path(INDEX);

  test("the honest witness for the leaf at index 2 is satisfiable", async () => {
    await ok(input());
  });

  test("a wrong secret fails", async () => {
    await fails(input({ secret: agent.secret + 1n }), LINE.inTree, "secret + 1");
    await fails(input({ secret: others[0].secret }), LINE.inTree, "another agent's secret");
  });

  test("changed attributes fail", async () => {
    for (const i of [0, 3, 12]) {
      await fails(input({ attributes: withAt(agent.attributes, i, agent.attributes[i] + 1n) }), LINE.inTree, `attr ${i}`);
    }
  });

  test("a wrong sibling at any level fails", async () => {
    for (const level of [0, 1, 7, 19]) {
      await fails(input({ siblings: withAt(siblings, level, siblings[level] + 1n) }), LINE.inTree, `level ${level}`);
    }
  });

  test("a flipped path bit at any level fails", async () => {
    for (const level of [0, 1, 2, 19]) {
      await fails(input({ pathBits: withAt(pathBits, level, 1n - pathBits[level]) }), LINE.inTree, `level ${level}`);
    }
  });

  test("a non-boolean path bit fails", async () => {
    await fails(input({ pathBits: withAt(pathBits, 0, 2n) }), LINE.pathBit, "pathBit = 2");
    await fails(input({ pathBits: withAt(pathBits, 5, C.R - 1n) }), LINE.pathBit, "pathBit = -1");
  });

  test("another leaf's path, or another root, fails", async () => {
    await fails(input({}, agent, tree, 1), LINE.inTree, "path of index 1");
    await fails(input({}, agent, tree, 3), LINE.inTree, "path of index 3");
    await fails(input({ root: tree.root + 1n }), LINE.inTree, "root + 1");
    await fails(input({ root: new C.Tree([C.leafOf(others[0])]).root }), LINE.inTree, "another tree's root");
  });
});
