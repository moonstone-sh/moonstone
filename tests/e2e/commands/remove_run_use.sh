#!/usr/bin/env bash
set -euo pipefail

source "${PROJECT_ROOT}/tests/scripts/lib/assert.sh"

WORKDIR="/tmp/moonstone-contract-remove-run-use"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}/project/subdir"
cd "${WORKDIR}/project"

moon init . --name rru-contract --no-git
moon interpreter set lua@5.4 --no-sync
moon add inspect@3.1.3 --no-sync

cat >> moonstone.toml <<'TOML'
hello = "echo hello-from-contract"
args = "printf 'args:<%s><%s><%s>\\n' \"$1\" \"$2\" \"$3\""
TOML

cd subdir
run_output=$(moon run hello)
assert_contains "${run_output}" "hello-from-contract" "run discovers parent script"

args_output=$(moon run args -- "hello world" --flag tail)
assert_contains "${args_output}" "args:<hello world><--flag><tail>" "run forwards args after --"

moon interpreter set lua@5.4.7 --no-sync

moon remove inspect
assert_file_not_contains "${WORKDIR}/project/moonstone.toml" '"inspect"'
assert_file_not_contains "${WORKDIR}/project/moonstone.lock" 'name = "inspect"'

missing_output=$(moon run missing 2>&1 || true)
assert_contains "${missing_output}" "script 'missing' not found" "missing script error"

cd /tmp
if moon remove inspect --no-sync >/tmp/moonstone-contract-remove-outside.out 2>&1; then
  echo "✗ remove outside project should fail"
  exit 1
fi
assert_contains "$(cat /tmp/moonstone-contract-remove-outside.out)" "not inside a Moonstone project" "remove outside project error"
