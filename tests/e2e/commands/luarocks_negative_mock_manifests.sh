#!/usr/bin/env bash
set -euo pipefail

source "${PROJECT_ROOT}/tests/scripts/lib/assert.sh"

WORKDIR="/tmp/moonstone-contract-luarocks-negative-mock-manifests"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

moon init . --name rocks-negative-mock-manifests --runtime lua@5.4 --no-sync --no-git
moon use lua@5.4

cat >> "${MOONSTONE_CONFIG}/config.toml" <<'TOML'
[network]
retries = 0
retry_delay = 0
TOML

start_mock() {
  local mode="$1"
  local port="$2"
  local dir="/tmp/moonstone-mock-rocks-negative-${mode}-${port}"
  rm -rf "${dir}"
  mkdir -p "${dir}"
  "${PROJECT_ROOT}/tests/run_lua_tool.sh" generate-mock-rocks "${dir}" "${port}" --mode "${mode}" >/tmp/moonstone-mock-${mode}.log 2>&1 &
  MOCK_PID=$!
  sleep 1
  export MOONSTONE_LUAROCKS_URL="http://127.0.0.1:${port}"
}

stop_mock() {
  kill "${MOCK_PID}" 2>/dev/null || true
  wait "${MOCK_PID}" 2>/dev/null || true
}

assert_manifest_failure() {
  local mode="$1"
  local port="$2"
  start_mock "${mode}" "${port}"
  local output
  output=$(moon add rocks:fakebin --no-sync 2>&1 || true)
  stop_mock
  assert_contains "${output}" "LuaRocks registry is unreachable" "${mode} plain LuaRocks error"
  assert_file_not_contains "moonstone.toml" 'fakebin'
}

assert_manifest_failure "invalid-json" 9711
assert_manifest_failure "manifest-404" 9712
assert_manifest_failure "manifest-500" 9713

start_mock "manifest-500" 9714
json_error=$(moon add rocks:fakebin --no-sync --json 2>/tmp/moonstone-contract-luarocks-negative-mock.err || true)
stop_mock
assert_json_valid "${json_error}"
assert_ndjson_terminator "${json_error}"
assert_last_json_field "${json_error}" "kind" "ERROR"
assert_last_json_field "${json_error}" "value" "error.RocksVersionDiscoveryFailed"
assert_last_json_field "${json_error}" "data.error_detail" "LuaRocks registry is unreachable or returned an invalid manifest"
assert_file_not_contains "moonstone.toml" 'fakebin'
