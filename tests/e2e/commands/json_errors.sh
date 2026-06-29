#!/usr/bin/env bash
set -euo pipefail

source "${PROJECT_ROOT}/tests/scripts/lib/assert.sh"

WORKDIR="/tmp/moonstone-contract-json-errors"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}/project"
cd "${WORKDIR}/project"

moon init . --name json-error-contract --no-git
moon use lua@5.4 --no-sync

run_error=$(moon run missing --json 2>&1 || true)
assert_json_valid "${run_error}"
assert_ndjson_terminator "${run_error}"
assert_last_json_field "${run_error}" "kind" "ERROR"
assert_last_json_field "${run_error}" "value" "error.ScriptNotFound"

flag_error=$(moon add --definitely-not-a-flag --json 2>&1 || true)
assert_json_valid "${flag_error}"
assert_ndjson_terminator "${flag_error}"
assert_last_json_field "${flag_error}" "kind" "ERROR"
assert_last_json_field "${flag_error}" "data.flag" "definitely-not-a-flag"

cd /tmp
outside_error=$(moon add inspect --json 2>&1 || true)
assert_json_valid "${outside_error}"
assert_ndjson_terminator "${outside_error}"
assert_last_json_field "${outside_error}" "kind" "ERROR"
assert_last_json_field "${outside_error}" "data.error_name" "NotInsideMoonstoneProject"
