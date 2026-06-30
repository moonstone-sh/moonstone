#!/usr/bin/env bash
set -euo pipefail

source "${PROJECT_ROOT}/tests/scripts/lib/assert.sh"

WORKDIR="/tmp/moonstone-contract-luarocks-negative-network"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

moon init . --name rocks-negative-network --interpreter lua@5.4 --no-sync --no-git
moon interpreter set lua@5.4

cat >> "${MOONSTONE_CONFIG}/config.toml" <<'TOML'
[network]
retries = 0
retry_delay = 0
TOML

export MOONSTONE_LUAROCKS_URL="http://127.0.0.1:9"

plain_error=$(moon add rocks:dkjson --no-sync 2>&1 || true)
assert_contains "${plain_error}" "no versions of dkjson match" "plain LuaRocks network error"
assert_file_not_contains "moonstone.toml" 'dkjson'

json_error=$(moon add rocks:dkjson --no-sync --json 2>/tmp/moonstone-contract-luarocks-negative-network.err || true)
assert_json_valid "${json_error}"
assert_ndjson_terminator "${json_error}"
assert_last_json_field "${json_error}" "kind" "ERROR"
assert_last_json_field "${json_error}" "value" "error.NoSolution"
assert_contains "${json_error}" "no versions of dkjson match" "json LuaRocks network error detail"
