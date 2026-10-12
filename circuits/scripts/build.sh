#!/usr/bin/env bash
# Compile the claims circuit into build/ (R1CS, witness-generator WASM, symbols).
# Needs circom 2.2.3 on PATH (nix shell nixpkgs#circom) and `npm ci` for circomlib.
set -euo pipefail
cd "$(dirname "$0")/.."
want="2.2.3"
have="$(circom --version | awk '{print $NF}')"
[[ "$have" == "$want" ]] || { echo "circom $want required, found $have" >&2; exit 1; }
mkdir -p build
circom agent_claims.circom --r1cs --wasm --sym --O2 -l node_modules -o build >/dev/null
echo "compiled: build/agent_claims.r1cs, build/agent_claims_js/agent_claims.wasm"
