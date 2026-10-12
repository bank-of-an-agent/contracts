#!/usr/bin/env bash
# TESTNET-ONLY trusted setup for the claims circuit.
#
# Groth16 needs a structured reference string. Whoever knows the setup's secret randomness
# ("toxic waste") can forge proofs. This script runs a single-party ceremony on one machine:
# acceptable for Base Sepolia, never for mainnet. Before mainnet, replace phase 1 with a public
# multi-party Powers of Tau and run a multi-party phase 2 (see docs/adr/0003-private-proofs.md).
#
# Outputs:
#   ceremony/pot14_final.ptau        phase-1 parameters (kept so CI can re-verify the zkey)
#   artifacts/agent_claims.zkey      proving key
#   artifacts/verification_key.json  verification key
#   ../src/verifiers/AgentClaimsGroth16Verifier.sol
#   ceremony/TRANSCRIPT.md           contribution hashes
set -euo pipefail
cd "$(dirname "$0")/.."
S=./node_modules/.bin/snarkjs
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
entropy() { head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

[[ -f build/agent_claims.r1cs ]] || scripts/build.sh

echo "phase 1: powers of tau (2^14, bn128)"
$S powersoftau new bn128 14 "$tmp/pot_0.ptau" >/dev/null
$S powersoftau contribute "$tmp/pot_0.ptau" "$tmp/pot_1.ptau" --name="Agent Bank testnet phase 1" -e="$(entropy)" >"$tmp/p1.log"
$S powersoftau beacon "$tmp/pot_1.ptau" "$tmp/pot_beacon.ptau" "$(entropy)" 10 -n="Agent Bank testnet phase 1 beacon" >/dev/null
$S powersoftau prepare phase2 "$tmp/pot_beacon.ptau" ceremony/pot14_final.ptau >/dev/null

echo "phase 2: circuit-specific setup"
$S groth16 setup build/agent_claims.r1cs ceremony/pot14_final.ptau "$tmp/claims_0.zkey" >/dev/null
$S zkey contribute "$tmp/claims_0.zkey" "$tmp/claims_1.zkey" --name="Agent Bank testnet phase 2" -e="$(entropy)" >"$tmp/p2.log"
$S zkey beacon "$tmp/claims_1.zkey" artifacts/agent_claims.zkey "$(entropy)" 10 -n="Agent Bank testnet phase 2 beacon" >/dev/null

scripts/export.sh

{
  echo "# Claims circuit trusted setup transcript"
  echo
  echo "**Testnet only.** A single party ran both phases on one machine on $(date -u +%Y-%m-%d)."
  echo "Proofs made with these keys are only as trustworthy as that machine. Before mainnet,"
  echo "replace them with a public multi-party ceremony (ADR 0003)."
  echo
  echo '```'
  $S zkey verify build/agent_claims.r1cs ceremony/pot14_final.ptau artifacts/agent_claims.zkey 2>&1 \
    | sed -E 's/^.*snarkJS[^:]*: //' | grep -vE '^\s*$'
  echo '```'
} >ceremony/TRANSCRIPT.md
echo "done: artifacts/, ceremony/ and ../src/verifiers/AgentClaimsGroth16Verifier.sol"
