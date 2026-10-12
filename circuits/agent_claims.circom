pragma circom 2.1.9;

// Agent Bank claims circuit, schema agentbank.claims.v1.
//
// Agent Bank attests facts about each enrolled agent in a Poseidon Merkle tree whose root it
// publishes on-chain (AgentAttestationRegistry). A leaf is
//
//     leaf = Poseidon(identity, Poseidon(attributes[0..12], disclosureMask))
//     identity = Poseidon(secret)
//
// where `secret` is known only to the agent. The agent proves, without revealing its leaf, its
// attributes or its position, that a leaf in a published tree belongs to it and that every
// attribute lies within the verifier's [min, max] bounds. Bounds on attributes the owner did not
// disclose (mask bit clear) must be the trivial [0, 2^64 - 1].
//
// Public signals, in snarkjs order:
//   [0] nullifier          Poseidon(secret, scope): stable per verifier scope, unlinkable across scopes
//   [1] root               a tree root published in the registry
//   [2] scope              the verifier's scope (a field element derived from its identifier)
//   [3] nonce              the verifier's challenge, bound into the proof
//   [4 .. 16]  mins[13]    lower bounds, one per attribute
//   [17 .. 29] maxs[13]    upper bounds, one per attribute
//
// Attribute layout (all values are integers below 2^64):
//   0 principal_verification  0 none, 1 verified individual, 2 verified company
//   1 per_tx_limit            USDC minor units; 2^64 - 1 means uncapped
//   2 per_day_limit           USDC minor units; 2^64 - 1 means uncapped
//   3 balance                 available USDC, minor units floored to whole dollars
//   4 reserved_amount         USDC minor units held for the scope in reserved_for
//   5 reserved_until          unix seconds the reservation lasts until
//   6 reserved_for            low 64 bits of the scope the reservation is for (0: none)
//   7 account_created_on      unix seconds, floored to the UTC day
//   8 payments_settled        count of settled outgoing payments
//   9 volume_settled          USDC minor units, floored to whole dollars
//  10 escrows_completed       escrows released to the agent as payee
//  11 disputes_lost           disputes resolved against the agent
//  12 counterparties          distinct counterparties with settled payments

include "circomlib/circuits/poseidon.circom";
include "circomlib/circuits/comparators.circom";
include "circomlib/circuits/bitify.circom";

template MerkleInclusion(depth) {
    signal input leaf;
    signal input siblings[depth];
    signal input pathBits[depth];
    signal output root;

    signal nodes[depth + 1];
    signal left[depth];
    signal right[depth];
    component hashers[depth];
    nodes[0] <== leaf;
    for (var i = 0; i < depth; i++) {
        // pathBits[i] = 1 when the current node is the right child.
        pathBits[i] * (pathBits[i] - 1) === 0;
        left[i] <== nodes[i] + pathBits[i] * (siblings[i] - nodes[i]);
        right[i] <== siblings[i] + nodes[i] - left[i];
        hashers[i] = Poseidon(2);
        hashers[i].inputs[0] <== left[i];
        hashers[i].inputs[1] <== right[i];
        nodes[i + 1] <== hashers[i].out;
    }
    root <== nodes[depth];
}

template AgentClaims(depth, nAttrs) {
    var MAX64 = 18446744073709551615;

    // Private inputs.
    signal input secret;
    signal input attributes[nAttrs];
    signal input disclosureMask;
    signal input siblings[depth];
    signal input pathBits[depth];

    // Public inputs.
    signal input root;
    signal input scope;
    signal input nonce;
    signal input mins[nAttrs];
    signal input maxs[nAttrs];

    signal output nullifier;

    component identity = Poseidon(1);
    identity.inputs[0] <== secret;

    component attributeHash = Poseidon(nAttrs + 1);
    for (var i = 0; i < nAttrs; i++) attributeHash.inputs[i] <== attributes[i];
    attributeHash.inputs[nAttrs] <== disclosureMask;

    component leaf = Poseidon(2);
    leaf.inputs[0] <== identity.out;
    leaf.inputs[1] <== attributeHash.out;

    component tree = MerkleInclusion(depth);
    tree.leaf <== leaf.out;
    for (var i = 0; i < depth; i++) {
        tree.siblings[i] <== siblings[i];
        tree.pathBits[i] <== pathBits[i];
    }
    tree.root === root;

    component maskBits = Num2Bits(nAttrs);
    maskBits.in <== disclosureMask;

    component attributeBits[nAttrs];
    component minBits[nAttrs];
    component maxBits[nAttrs];
    component atLeastMin[nAttrs];
    component atMostMax[nAttrs];
    for (var i = 0; i < nAttrs; i++) {
        // Every compared value fits in 64 bits, so the comparators below are sound.
        attributeBits[i] = Num2Bits(64);
        attributeBits[i].in <== attributes[i];
        minBits[i] = Num2Bits(64);
        minBits[i].in <== mins[i];
        maxBits[i] = Num2Bits(64);
        maxBits[i].in <== maxs[i];

        atLeastMin[i] = LessEqThan(64);
        atLeastMin[i].in[0] <== mins[i];
        atLeastMin[i].in[1] <== attributes[i];
        atLeastMin[i].out === 1;

        atMostMax[i] = LessEqThan(64);
        atMostMax[i].in[0] <== attributes[i];
        atMostMax[i].in[1] <== maxs[i];
        atMostMax[i].out === 1;

        // An attribute the owner did not disclose cannot be constrained at all.
        (1 - maskBits.out[i]) * mins[i] === 0;
        (1 - maskBits.out[i]) * (maxs[i] - MAX64) === 0;
    }

    component nullifierHash = Poseidon(2);
    nullifierHash.inputs[0] <== secret;
    nullifierHash.inputs[1] <== scope;
    nullifier <== nullifierHash.out;

    // Bind the challenge into the proof: an unconstrained public input could be altered freely.
    signal nonceSquared <== nonce * nonce;
}

component main {public [root, scope, nonce, mins, maxs]} = AgentClaims(20, 13);
