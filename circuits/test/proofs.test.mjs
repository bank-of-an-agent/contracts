// Completeness and binding: real Groth16 proofs with the committed artifacts, one per product, from leaves at odd
// and even indexes of a multi-leaf tree; nullifiers; and every public signal and proof element being bound.
//
// Proving takes ~1.5 s, so each proof is made once (before()) and reused across the tests below.
import assert from "node:assert/strict";
import { after, before, describe, test } from "node:test";

import * as C from "../lib/claims.mjs";

after(C.shutdown);

const NOW = 1_760_000_000n; // the snapshot time the attributes are "as of"
const DAY = 86_400n;
const SELLER = C.httpScope("api.seller.example");
const OTHER = C.httpScope("api.other.example");
const nonce = (label) => BigInt(C.keccakHex(label)) >> 8n; // 31 bytes

const company = {
  secret: 0xc0_4a_11n,
  attributes: C.attributesOf({
    principal_verification: 2,
    per_tx_limit: 10_000000,
    per_day_limit: 250_000000,
    balance: 40_000000,
    account_created_on: NOW - 400n * DAY,
  }),
  mask: C.maskOf("principal", "limits"),
};
const veteran = {
  secret: 0x7e_7e_4a_11n,
  attributes: C.attributesOf({
    principal_verification: 1,
    account_created_on: NOW - 200n * DAY,
    payments_settled: 1_250,
    volume_settled: 98_000_000000,
    escrows_completed: 31,
    disputes_lost: 0,
    counterparties: 64,
  }),
  mask: C.maskOf("reputation", "account_age"),
};
const saverBase = {
  secret: 0x5a_7e_4n,
  attributes: C.attributesOf({ principal_verification: 2, balance: 2_500_000000, account_created_on: NOW - 30n * DAY }),
  mask: C.maskOf("balance", "reservations"),
};
// The saver's reservation for SELLER is a second leaf with the same identity (same secret).
const saverReservation = {
  ...saverBase,
  attributes: C.attributesOf({
    principal_verification: 2,
    balance: 2_500_000000,
    reserved_amount: 750_000000,
    reserved_until: NOW + 3n * DAY,
    reserved_for: C.tagOf(SELLER),
    account_created_on: NOW - 30n * DAY,
  }),
};
const filler = (secret) => ({ secret, attributes: C.attributesOf({ balance: secret }), mask: C.FULL_MASK });

// index: 0 filler, 1 filler, 2 company (even), 3 veteran (odd), 4 saver (even), 5 saver's reservation (odd), 6 filler
const members = [filler(1n), filler(2n), company, veteran, saverBase, saverReservation, filler(3n)];
const tree = new C.Tree(members.map(C.leafOf));

const products = {
  verifiedCompanyWithLimits: {
    index: 2,
    scope: SELLER,
    nonce: nonce("company"),
    ...C.bounds({
      principal_verification: [2, 2], // verifiedCompany()
      per_tx_limit: [5_000000], // canPayPerTx(5.00)
      per_day_limit: [, 1_000_000000], // spendingCappedAt({ perDay: 1000.00 })
    }),
  },
  reputation: {
    index: 3,
    scope: SELLER,
    nonce: nonce("reputation"),
    ...C.bounds({
      payments_settled: [1_000],
      volume_settled: [50_000_000000],
      escrows_completed: [25],
      disputes_lost: [, 0],
      counterparties: [50],
      account_created_on: [, NOW - 90n * DAY], // accountOlderThan(90)
    }),
  },
  balance: {
    index: 4,
    scope: OTHER,
    nonce: nonce("balance"),
    ...C.bounds({ balance: [1_000_000000] }), // balanceAtLeast(1000.00)
  },
  reservation: {
    index: 5,
    scope: SELLER,
    nonce: nonce("reservation"),
    ...C.bounds({
      reserved_amount: [500_000000],
      reserved_until: [NOW + DAY],
      reserved_for: [C.tagOf(SELLER), C.tagOf(SELLER)], // reservedFor(500.00, { until })
    }),
  },
};

const vkey = C.verificationKey();
const made = {};

before(async () => {
  for (const [name, p] of Object.entries(products)) {
    const input = C.circuitInput({ agent: members[p.index], tree, ...p });
    made[name] = await C.prove(input);
  }
});

describe("products", () => {
  for (const [name, p] of Object.entries(products)) {
    test(`${name}: a valid proof from leaf ${p.index} verifies with the expected public signals`, async () => {
      const { proof, publicSignals } = made[name];
      const agent = members[p.index];
      const expected = C.publicSignalsOf({
        nullifier: C.nullifierOf(agent.secret, p.scope),
        root: tree.root,
        scope: p.scope,
        nonce: p.nonce,
        mins: p.mins,
        maxs: p.maxs,
      });
      assert.deepEqual(publicSignals, expected);
      assert.equal(await C.verify(vkey, publicSignals, proof), true);
    });
  }

  test("the reservation proves nothing to another verifier", async () => {
    const p = products.reservation;
    const otherTag = C.bounds({ reserved_for: [C.tagOf(OTHER), C.tagOf(OTHER)] });
    const input = C.circuitInput({ agent: saverReservation, tree, ...p, scope: OTHER, ...otherTag });
    assert.match(await C.witnessError(input), /line: (125|130)/);
    // ...and the base leaf (no reservation) cannot claim one at all.
    const base = C.circuitInput({ agent: saverBase, tree, ...p, index: 4 });
    assert.match(await C.witnessError(base), /line: 125/);
  });

  test("a leaf at the far end of a sparse tree (all path bits 1) and at index 0 are provable", async () => {
    const leaves = new Map([
      [0, C.leafOf(company)],
      [2 ** 19, C.leafOf(filler(9n))],
      [2 ** C.DEPTH - 1, C.leafOf(veteran)],
    ]);
    const sparse = new C.Tree(leaves);
    assert.deepEqual(sparse.path(2 ** C.DEPTH - 1).pathBits, Array(C.DEPTH).fill(1n));
    const v = products.reputation;
    const w = await C.witness(C.circuitInput({ agent: veteran, tree: sparse, ...v, index: 2 ** C.DEPTH - 1 }));
    assert.equal(w[2], sparse.root, "public root wire");
    const c = products.verifiedCompanyWithLimits;
    assert.equal(await C.witnessError(C.circuitInput({ agent: company, tree: sparse, ...c, index: 0 })), null);
  });
});

describe("nullifier", () => {
  const nullifierWire = async (agent, index, scope, n = 1n) =>
    (await C.witness(C.circuitInput({ agent, tree, index, scope, nonce: n, ...C.bounds() })))[1];

  test("nullifier = Poseidon2(secret, scope)", async () => {
    assert.equal(await nullifierWire(company, 2, SELLER), C.nullifierOf(company.secret, SELLER));
  });

  test("stable per (agent, scope): independent of nonce, bounds and which of the agent's leaves", async () => {
    const n = await nullifierWire(saverBase, 4, SELLER, 1n);
    assert.equal(await nullifierWire(saverBase, 4, SELLER, 2n), n);
    assert.equal(await nullifierWire(saverReservation, 5, SELLER, 3n), n);
    assert.equal(made.reservation.publicSignals[0], n.toString());
  });

  test("differs by scope and by agent", async () => {
    const a = await nullifierWire(company, 2, SELLER);
    assert.notEqual(await nullifierWire(company, 2, OTHER), a);
    assert.notEqual(await nullifierWire(veteran, 3, SELLER), a);
    assert.notEqual(made.balance.publicSignals[0], C.nullifierOf(saverBase.secret, SELLER).toString());
  });

  test("the nullifier is not the identity committed in the tree", () => {
    assert.notEqual(C.nullifierOf(company.secret, SELLER), C.identityOf(company.secret));
  });
});

describe("binding", () => {
  const signalNames = [
    "nullifier",
    "root",
    "scope",
    "nonce",
    ...C.ATTRIBUTES.map((a) => `min.${a}`),
    ...C.ATTRIBUTES.map((a) => `max.${a}`),
  ];

  test("tampering any of the 30 public signals makes the proof invalid", async () => {
    const { proof, publicSignals } = made.verifiedCompanyWithLimits;
    assert.equal(publicSignals.length, 30);
    for (let i = 0; i < publicSignals.length; i++) {
      const v = BigInt(publicSignals[i]);
      for (const t of [(v + 1n) % C.R, (v + C.R - 1n) % C.R, v + C.R]) {
        const tampered = publicSignals.map((s, j) => (j === i ? t.toString() : s));
        assert.equal(await C.verify(vkey, tampered, proof), false, `signal ${i} (${signalNames[i]}) = ${t}`);
      }
    }
  });

  test("tampering the proof points makes the proof invalid", async () => {
    const { proof, publicSignals } = made.verifiedCompanyWithLimits;
    const clone = () => JSON.parse(JSON.stringify(proof));
    const bump = (s) => (BigInt(s) + 1n).toString();
    const variants = {
      "pi_a.x": (p) => (p.pi_a[0] = bump(p.pi_a[0])),
      "pi_a.y": (p) => (p.pi_a[1] = bump(p.pi_a[1])),
      "pi_b.x.c0": (p) => (p.pi_b[0][0] = bump(p.pi_b[0][0])),
      "pi_b.x.c1": (p) => (p.pi_b[0][1] = bump(p.pi_b[0][1])),
      "pi_b.y.c0": (p) => (p.pi_b[1][0] = bump(p.pi_b[1][0])),
      "pi_b.y.c1": (p) => (p.pi_b[1][1] = bump(p.pi_b[1][1])),
      "pi_c.x": (p) => (p.pi_c[0] = bump(p.pi_c[0])),
      "pi_c.y": (p) => (p.pi_c[1] = bump(p.pi_c[1])),
      "pi_b coordinates swapped": (p) => (p.pi_b = p.pi_b.map((pair, k) => (k < 2 ? [pair[1], pair[0]] : pair))),
      "pi_a and pi_c swapped": (p) => ([p.pi_a, p.pi_c] = [p.pi_c, p.pi_a]),
      "pi_a negated": (p) => (p.pi_a[1] = (C.Q - BigInt(p.pi_a[1])).toString()),
    };
    for (const [name, mutate] of Object.entries(variants)) {
      const p = clone();
      mutate(p);
      assert.equal(await C.verify(vkey, publicSignals, p), false, name);
    }
  });

  test("a proof is only valid for its own statement", async () => {
    for (const [name, { proof }] of Object.entries(made)) {
      for (const [other, { publicSignals }] of Object.entries(made)) {
        assert.equal(await C.verify(vkey, publicSignals, proof), name === other, `${name} proof vs ${other} signals`);
      }
    }
  });

  test("Solidity calldata order: b pairs swapped, signals as 32-byte words", async () => {
    const { proof, publicSignals } = made.reservation;
    const cd = await C.solidityCalldata(proof, publicSignals);
    const hex = (s) => `0x${BigInt(s).toString(16).padStart(64, "0")}`;
    assert.deepEqual(cd.a, [hex(proof.pi_a[0]), hex(proof.pi_a[1])]);
    assert.deepEqual(cd.b, [
      [hex(proof.pi_b[0][1]), hex(proof.pi_b[0][0])],
      [hex(proof.pi_b[1][1]), hex(proof.pi_b[1][0])],
    ]);
    assert.deepEqual(cd.c, [hex(proof.pi_c[0]), hex(proof.pi_c[1])]);
    assert.deepEqual(cd.signals, publicSignals.map(hex));
  });
});
