#!/usr/bin/env bash
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${PROJECT_ROOT}/fixtures/tests/commands"
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"

source "${PROJECT_ROOT}/install_synthetic.sh"
export PATH="${MOON_BIN%/*}:${PATH}"
export SANDBOX_DIR="${PROJECT_ROOT}/fixtures/sandbox"
export PROJECT_ROOT

PASS=0
FAIL=0

run_test_file() {
  local test_file="$1"
  local label
  label=$(basename "${test_file}")
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "  Running Contract Test: ${label}"
  echo "═══════════════════════════════════════════════════════════════════"
  if bash "${test_file}"; then
    echo "  ✓ ${label} passed"
    ((PASS+=1))
  else
    echo "  ✗ ${label} failed"
    ((FAIL+=1))
  fi
}

for f in "${TESTS_DIR}"/*.sh; do
  [[ -f "$f" ]] && run_test_file "$f"
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Contract Results: ${PASS} passed, ${FAIL} failed"
echo "═══════════════════════════════════════════════════════════════════"

if (( FAIL > 0 )); then
  exit 1
fi
