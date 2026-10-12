#!/usr/bin/env bash
# CI: prove the committed artifacts come from the committed circuit.
#   1. the circuit compiles to the R1CS and WASM recorded in the manifest (circom is deterministic)
#   2. the proving key verifies against that R1CS and the committed phase-1 parameters
#   3. the verification key, Solidity verifier and manifest re-derive byte for byte
set -euo pipefail
cd "$(dirname "$0")/.."
S=./node_modules/.bin/snarkjs
scripts/build.sh >/dev/null
r1cs="$(sha256sum build/agent_claims.r1cs | cut -d' ' -f1)"
wasm="$(sha256sum build/agent_claims_js/agent_claims.wasm | cut -d' ' -f1)"
[[ "$r1cs" == "$(jq -r .sha256.r1cs artifacts/manifest.json)" ]] || { echo "::error::circuit changed: R1CS hash differs from artifacts/manifest.json (rerun the ceremony)"; exit 1; }
[[ "$wasm" == "$(jq -r .sha256.wasm artifacts/manifest.json)" ]] || { echo "::error::witness WASM differs from artifacts/manifest.json"; exit 1; }
$S zkey verify build/agent_claims.r1cs ceremony/pot14_final.ptau artifacts/agent_claims.zkey 2>&1 | grep -q "ZKey Ok!" \
  || { echo "::error::artifacts/agent_claims.zkey does not verify against the circuit and ceremony/pot14_final.ptau"; exit 1; }
scripts/export.sh >/dev/null
git diff --exit-code -- artifacts/ ../src/verifiers/ \
  || { echo "::error::derived artifacts are stale: run scripts/export.sh and commit"; exit 1; }
echo "circuit artifacts verified"
