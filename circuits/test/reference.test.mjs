// The reference implementation (lib/claims.mjs) agrees with the circuit, the manifest and the design.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { after, describe, test } from "node:test";
import { poseidon1, poseidon2, poseidon14 } from "poseidon-lite";

import * as C from "../lib/claims.mjs";

after(C.shutdown);

const manifest = JSON.parse(readFileSync(new URL("../artifacts/manifest.json", import.meta.url), "utf8"));

describe("layout", () => {
  test("attributes and public signals match the manifest and the verification key", () => {
    assert.deepEqual(C.ATTRIBUTES, manifest.attributes);
    assert.equal(manifest.tree_depth, C.DEPTH);
    assert.deepEqual(manifest.public_signals, [
      "nullifier",
      "root",
      "scope",
      "nonce",
      ...C.ATTRIBUTES.map((a) => `min.${a}`),
      ...C.ATTRIBUTES.map((a) => `max.${a}`),
    ]);
    const vkey = C.verificationKey();
    assert.equal(vkey.protocol, "groth16");
    assert.equal(vkey.curve, "bn128");
    assert.equal(vkey.nPublic, 30);
    assert.equal(vkey.IC.length, 31);
  });

  test("disclosure classes partition the 13 attributes", () => {
    const all = Object.keys(C.CLASSES);
    assert.equal(C.maskOf(...all), C.FULL_MASK);
    let seen = 0n;
    for (const c of all) {
      const m = C.maskOf(c);
      assert.equal(seen & m, 0n, `${c} overlaps another class`);
      seen |= m;
    }
    assert.equal(C.maskOf("principal"), 1n);
    assert.equal(C.maskOf("limits"), 0b110n);
    assert.equal(C.maskOf("reservations"), 0b1110000n);
    assert.throws(() => C.maskOf("everything"));
  });

  test("bounds default to [0, 2^64 - 1] and reject unknown attributes", () => {
    const { mins, maxs } = C.bounds({ per_tx_limit: [5_000000], disputes_lost: [undefined, 0] });
    assert.equal(mins[C.IDX.per_tx_limit], 5_000000n);
    assert.equal(maxs[C.IDX.per_tx_limit], C.MAX64);
    assert.equal(mins[C.IDX.disputes_lost], 0n);
    assert.equal(maxs[C.IDX.disputes_lost], 0n);
    assert.equal(mins.filter((v) => v !== 0n).length, 1);
    assert.equal(maxs.filter((v) => v !== C.MAX64).length, 1);
    assert.throws(() => C.bounds({ shoe_size: [1, 2] }));
    assert.throws(() => C.attributesOf({ shoe_size: 1 }));
  });
});

describe("tree", () => {
  test("zero hashes: zero[0] = 0, zero[i+1] = Poseidon2(zero[i], zero[i])", () => {
    assert.equal(C.ZEROS.length, C.DEPTH + 1);
    assert.equal(C.ZEROS[0], 0n);
    for (let i = 0; i < C.DEPTH; i++) assert.equal(C.ZEROS[i + 1], poseidon2([C.ZEROS[i], C.ZEROS[i]]));
    assert.equal(new C.Tree([]).root, C.ZEROS[C.DEPTH]);
  });

  test("leaf = Poseidon2(Poseidon1(secret), Poseidon14(attributes, mask))", () => {
    const agent = { secret: 99n, attributes: C.attributesOf({ balance: 1_000_000000 }), mask: C.maskOf("balance") };
    const expected = poseidon2([poseidon1([99n]), poseidon14([...agent.attributes, agent.mask])]);
    assert.equal(C.leafOf(agent), expected);
  });

  test("a single leaf at index 0 folds left with zero siblings", () => {
    const leaf = 1234n;
    let node = leaf;
    for (let i = 0; i < C.DEPTH; i++) node = poseidon2([node, C.ZEROS[i]]);
    const tree = new C.Tree([leaf]);
    assert.equal(tree.root, node);
    assert.equal(tree.leafCount, 1);
    const { siblings, pathBits } = tree.path(0);
    assert.deepEqual(siblings, C.ZEROS.slice(0, C.DEPTH));
    assert.deepEqual(pathBits, Array(C.DEPTH).fill(0n));
  });

  test("paths recompute the root at odd and even indexes; pathBits are the index bits", () => {
    const leaves = [11n, 22n, 33n, 44n, 55n];
    const tree = new C.Tree(leaves);
    leaves.forEach((leaf, index) => {
      const { siblings, pathBits } = tree.path(index);
      let node = leaf;
      for (let i = 0; i < C.DEPTH; i++) {
        assert.equal(pathBits[i], BigInt((index >> i) & 1));
        node = pathBits[i] === 1n ? poseidon2([siblings[i], node]) : poseidon2([node, siblings[i]]);
      }
      assert.equal(node, tree.root, `index ${index}`);
    });
    assert.equal(tree.path(4).siblings[0], 0n, "the last odd leaf's sibling is an empty leaf");
  });

  test("sparse and dense trees agree; indexes are bounded by the depth", () => {
    const dense = new C.Tree([1n, 2n, 0n, 4n]);
    const sparse = new C.Tree(
      new Map([
        [0, 1n],
        [1, 2n],
        [3, 4n],
      ]),
    );
    assert.equal(sparse.root, dense.root);
    assert.throws(() => new C.Tree(new Map([[2 ** C.DEPTH, 1n]])));
    assert.throws(() => new C.Tree(new Map([[-1, 1n]])));
  });
});

describe("scopes", () => {
  test("HTTP and on-chain scopes are field elements; the tag is the low 64 bits", () => {
    const http = C.httpScope("api.seller.example");
    assert.ok(http > 0n && http < C.R);
    assert.notEqual(http, C.httpScope("api.other.example"));
    const onchain = C.onchainScope(84532, "0x00000000000000000000000000000000000a11ce", C.keccakHex("ctx"));
    assert.ok(onchain > 0n && onchain < C.R);
    assert.notEqual(onchain, C.onchainScope(31337, "0x00000000000000000000000000000000000a11ce", C.keccakHex("ctx")));
    assert.notEqual(onchain, C.onchainScope(84532, "0x00000000000000000000000000000000000b0b00", C.keccakHex("ctx")));
    assert.notEqual(onchain, C.onchainScope(84532, "0x00000000000000000000000000000000000a11ce", C.keccakHex("ctx2")));
    assert.equal(C.tagOf(http), http % (1n << 64n));
  });

  test("keccak matches the Ethereum test vector", () => {
    assert.equal(C.keccakHex(""), "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470");
  });
});
