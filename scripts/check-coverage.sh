#!/usr/bin/env bash
# Fails unless every listed source file has 100% line and function coverage in an lcov report.
#
# Usage: scripts/check-coverage.sh [lcov.info] [file ...]
#   defaults: lcov.info, and the private-proofs contracts (src/AgentAttestationRegistry.sol, src/AgentClaimsVerifier.sol)
# Produce the report with: forge coverage --report lcov --no-match-coverage '^(test|script)/'
set -euo pipefail

cd "$(dirname "$0")/.."
LCOV="${1:-lcov.info}"
shift || true
FILES=("$@")
if [[ ${#FILES[@]} -eq 0 ]]; then
  FILES=("src/AgentAttestationRegistry.sol" "src/AgentClaimsVerifier.sol")
fi
[[ -f "$LCOV" ]] || { echo "::error::$LCOV not found (run forge coverage --report lcov first)"; exit 1; }

status=0
for file in "${FILES[@]}"; do
  # One record per source file: SF:<path> ... LF/LH (lines found/hit), FNF/FNH (functions) ... end_of_record.
  if ! awk -v file="$file" '
    $0 == "SF:" file { inside = 1; found = 1; next }
    inside && /^LF:/ { lf = substr($0, 4) }
    inside && /^LH:/ { lh = substr($0, 4) }
    inside && /^FNF:/ { fnf = substr($0, 5) }
    inside && /^FNH:/ { fnh = substr($0, 5) }
    inside && $0 == "end_of_record" { inside = 0 }
    END {
      if (!found) { printf "::error::%s is missing from the coverage report\n", file; exit 1 }
      if (lf == "" || lf + 0 == 0) { printf "::error::%s has no instrumented lines\n", file; exit 1 }
      printf "%s: lines %s/%s, functions %s/%s\n", file, lh, lf, fnh, fnf
      if (lh + 0 < lf + 0 || fnh + 0 < fnf + 0) { printf "::error::%s is below 100%% line or function coverage\n", file; exit 1 }
    }
  ' "$LCOV"; then
    status=1
  fi
done
exit "$status"
