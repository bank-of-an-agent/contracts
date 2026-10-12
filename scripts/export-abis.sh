#!/usr/bin/env bash
# Writes clean ABI JSON for every deployable contract to abis/<Contract>.json.
#
# TypeScript (viem/wagmi) and Python (web3.py) consumers copy these files verbatim. Each file is the bare ABI array
# (no bytecode or metadata), pretty-printed with a trailing newline so diffs stay reviewable. CI re-runs this script
# and fails if abis/ is stale.
#
# Usage: scripts/export-abis.sh            (uses `forge` from PATH; override with FORGE=/path/to/forge)
set -euo pipefail

cd "$(dirname "$0")/.."
FORGE="${FORGE:-forge}"
OUT_DIR="abis"

# Path to source file : contract name.
CONTRACTS=(
  "src/AgentEscrow.sol:AgentEscrow"
  "src/PaymentStreams.sol:PaymentStreams"
  "src/AgentPolicyHook.sol:AgentPolicyHook"
  "src/TimeLockVaults.sol:TimeLockVaults"
  "src/SweepExecutor.sol:SweepExecutor"
  "src/TopUpExecutor.sol:TopUpExecutor"
  "src/mocks/MockUSDC.sol:MockUSDC"
  "src/mocks/MockTreasuryFund.sol:MockTreasuryFund"
  "src/mocks/MockValidationRegistry.sol:MockValidationRegistry"
)

"$FORGE" build --skip test --skip script >/dev/null

mkdir -p "$OUT_DIR"
find "$OUT_DIR" -maxdepth 1 -name '*.json' -delete

for entry in "${CONTRACTS[@]}"; do
  name="${entry##*:}"
  "$FORGE" inspect "$entry" abi --json | jq --indent 2 '.' > "$OUT_DIR/$name.json"
  echo "wrote $OUT_DIR/$name.json ($(jq length "$OUT_DIR/$name.json") entries)"
done
