#!/usr/bin/env bash
set -euo pipefail

# Validate a pinned LuaRocks rockspec corpus against Moonstone's bridge. This
# intentionally does not invoke the LuaRocks CLI: it proves declaration parsing
# and preservation, not command or build-backend parity.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CORPUS_DIR="${PROJECT_ROOT}/tests/upstream/luarocks"
UPSTREAM_REVISION="665f160b4d0b79e85e66c6cc83e442d72eb40868"
LUA_BIN="${LUA_BIN:-$(command -v luajit || command -v lua || true)}"

if [[ -z "${LUA_BIN}" ]]; then
  echo "ERROR: LuaJIT or Lua is required for upstream rockspec bridge conformance." >&2
  exit 1
fi

corpus_value() {
  local key="$1"
  awk -F ' = ' -v key="${key}" '$1 == key { gsub(/"/, "", $2); print $2; exit }' "${CORPUS_DIR}/corpus.toml"
}

assert_corpus_count() {
  local key="$1"
  local actual="$2"
  local expected
  expected="$(corpus_value "${key}")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "ERROR: corpus metadata mismatch for ${key}: expected ${expected}, found ${actual}" >&2
    exit 1
  fi
}

assert_corpus_count "upstream_fixture_count" "$(find "${CORPUS_DIR}/fixtures/upstream" -name '*.rockspec' -type f | wc -l | tr -d ' ')"
assert_corpus_count "moonstone_fixture_count" "$(find "${CORPUS_DIR}/fixtures/moonstone" -name '*.rockspec' -type f | wc -l | tr -d ' ')"
assert_corpus_count "syntax_rejection_count" "$(awk -F $'\t' '$1 == "reject_syntax" { count += 1 } END { print count + 0 }' "${CORPUS_DIR}/expectations.tsv")"
assert_corpus_count "semantic_rejection_count" "$(awk -F $'\t' '$1 ~ /^reject_semantic:/ { count += 1 } END { print count + 0 }' "${CORPUS_DIR}/expectations.tsv")"
assert_corpus_count "expected_parser_acceptance_count" "$(awk -F $'\t' '$1 == "accept" { count += 1 } END { print count + 0 }' "${CORPUS_DIR}/expectations.tsv")"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

verify_snapshot() {
  local expected_hash="$1"
  local snapshot="$2"
  local actual_hash
  actual_hash="$(sha256_file "${CORPUS_DIR}/${snapshot}")"
  if [[ "${actual_hash}" != "${expected_hash}" ]]; then
    echo "ERROR: upstream fixture snapshot hash mismatch: ${snapshot}" >&2
    exit 1
  fi
}

while IFS=$'\t' read -r expected_hash snapshot; do
  [[ -z "${expected_hash}" ]] && continue
  verify_snapshot "${expected_hash}" "${snapshot}"
done < "${CORPUS_DIR}/fixtures.sha256"

if [[ -n "${LUAROCKS_UPSTREAM_DIR:-}" ]]; then
  actual_revision="$(git -C "${LUAROCKS_UPSTREAM_DIR}" rev-parse HEAD)"
  test "${actual_revision}" = "${UPSTREAM_REVISION}"
  while IFS=$'\t' read -r _ snapshot; do
    [[ "${snapshot}" == fixtures/upstream/* ]] || continue
    upstream_path="${snapshot#fixtures/upstream/}"
    cmp "${CORPUS_DIR}/${snapshot}" "${LUAROCKS_UPSTREAM_DIR}/spec/fixtures/${upstream_path}"
  done < "${CORPUS_DIR}/fixtures.sha256"
fi

assert_upstream_schema_expectation() {
  local expectation="$1"
  local fixture="$2"
  local output
  local status

  if output="$("${LUA_BIN}" "${CORPUS_DIR}/upstream_schema_check.lua" "${LUAROCKS_UPSTREAM_DIR}" "${CORPUS_DIR}/${fixture}" 2>&1)"; then
    status=0
  else
    status=$?
  fi

  case "${expectation}" in
    accept)
      if [[ "${status}" -ne 0 ]]; then
        echo "ERROR: upstream LuaRocks schema rejected an accepted fixture: ${fixture}" >&2
        printf '%s\n' "${output}" >&2
        exit 1
      fi
      ;;
    reject_syntax)
      if [[ "${status}" -ne 2 ]]; then
        echo "ERROR: upstream LuaRocks schema did not classify fixture as syntax-invalid: ${fixture}" >&2
        printf '%s\n' "${output}" >&2
        exit 1
      fi
      ;;
    reject_semantic:*)
      if [[ "${status}" -ne 3 ]]; then
        echo "ERROR: upstream LuaRocks schema did not reject semantic fixture: ${fixture}" >&2
        printf '%s\n' "${output}" >&2
        exit 1
      fi
      ;;
    *)
      echo "ERROR: unknown parser expectation: ${expectation}" >&2
      exit 1
      ;;
  esac
}

assert_bridge_accepts() {
  local fixture="$1"
  local output
  output="$("${LUA_BIN}" "${PROJECT_ROOT}/src/core/luarocks/bridge.lua" "${CORPUS_DIR}/${fixture}")"

  printf '%s' "${output}" | jq -e '
    .document | type == "object"
  ' >/dev/null
  printf '%s' "${output}" | jq -e '
    .document.package == .package and .document.version == .version
  ' >/dev/null
}

assert_bridge_rejects_syntax() {
  local fixture="$1"
  if "${LUA_BIN}" "${PROJECT_ROOT}/src/core/luarocks/bridge.lua" "${CORPUS_DIR}/${fixture}" >/dev/null 2>&1; then
    echo "ERROR: parser accepted an intentionally malformed fixture: ${fixture}" >&2
    exit 1
  fi
}

assert_bridge_rejects_semantics() {
  local fixture="$1"
  local expected_code="$2"
  local error_output
  if error_output="$("${LUA_BIN}" "${PROJECT_ROOT}/src/core/luarocks/bridge.lua" "${CORPUS_DIR}/${fixture}" 2>&1)"; then
    echo "ERROR: parser accepted a semantically unsupported fixture: ${fixture}" >&2
    exit 1
  fi
  printf '%s' "${error_output}" | grep -F "[${expected_code}]" >/dev/null
}

while IFS=$'\t' read -r expectation fixture; do
  if [[ -n "${LUAROCKS_UPSTREAM_DIR:-}" ]]; then
    assert_upstream_schema_expectation "${expectation}" "${fixture}"
  fi
  case "${expectation}" in
    accept) assert_bridge_accepts "${fixture}" ;;
    reject_syntax) assert_bridge_rejects_syntax "${fixture}" ;;
    reject_semantic:*) assert_bridge_rejects_semantics "${fixture}" "${expectation#reject_semantic:}" ;;
    *) echo "ERROR: unknown parser expectation: ${expectation}" >&2; exit 1 ;;
  esac
done < "${CORPUS_DIR}/expectations.tsv"

surface_output="$("${LUA_BIN}" "${PROJECT_ROOT}/src/core/luarocks/bridge.lua" "${CORPUS_DIR}/fixtures/moonstone/format-3.1-surface.rockspec")"
printf '%s' "${surface_output}" | jq -e '
  .document.rockspec_format == "3.1" and
  .document.source.cvs_module == "surface-cvs" and
  .document.description.labels == ["parser", "coverage"] and
  .document.supported_platforms == ["unix", "win32"] and
  .document.dependencies.platforms.unix[0] == "luafilesystem >= 1.8" and
  .document.build_dependencies.platforms.win32[0] == "winapi" and
  .document.test_dependencies.platforms.unix[0] == "busted >= 2" and
  .document.external_dependencies.FOO.library == "foo" and
  .document.build.copy_directories[0] == "assets" and
  .document.build.platforms.unix.modules["surface.unix"] == "src/unix.lua" and
  .document.test.platforms.unix.type == "busted" and
  .document.hooks.post_install == "echo installed" and
  .document.deploy.wrap_bin_scripts == false
' >/dev/null

no_build_output="$("${LUA_BIN}" "${PROJECT_ROOT}/src/core/luarocks/bridge.lua" "${CORPUS_DIR}/fixtures/moonstone/format-3.0-no-build.rockspec")"
printf '%s' "${no_build_output}" | jq -e '
  .document.build == null and
  .build.type == "builtin" and
  .dependencies == ["lua >= 5.1"]
' >/dev/null

linux_intent_output="$("${LUA_BIN}" "${PROJECT_ROOT}/src/core/luarocks/bridge.lua" "${CORPUS_DIR}/fixtures/moonstone/format-3.1-surface.rockspec" linux)"
printf '%s' "${linux_intent_output}" | jq -e '
  .intent.platform == "linux" and
  .intent.source.url == "https://example.invalid/surface-unix.tar.gz" and
  .intent.source.module == "surface-cvs" and
  .intent.source.tag == "SURFACE_1_2_3" and
  .intent.source.dir == "surface-1.2.3" and
  .intent.dependencies == ["luafilesystem >= 1.8"] and
  .intent.build.modules["surface.unix"] == "src/unix.lua"
' >/dev/null

windows_intent_output="$("${LUA_BIN}" "${PROJECT_ROOT}/src/core/luarocks/bridge.lua" "${CORPUS_DIR}/fixtures/moonstone/format-3.1-surface.rockspec" win32)"
printf '%s' "${windows_intent_output}" | jq -e '
  .intent.platform == "win32" and
  .intent.source.url == "https://example.invalid/surface-win.zip" and
  .intent.source.module == "surface-cvs" and
  .intent.source.tag == "SURFACE_1_2_3" and
  .intent.source.dir == "surface-1.2.3" and
  .intent.dependencies == ["winapi"] and
  .intent.build.modules["surface.windows"] == "src/windows.lua"
' >/dev/null

cvs_source_output="$("${LUA_BIN}" "${PROJECT_ROOT}/src/core/luarocks/bridge.lua" "${CORPUS_DIR}/fixtures/moonstone/cvs-source-normalization.rockspec" linux)"
printf '%s' "${cvs_source_output}" | jq -e '
  .intent.source.module == "legacy-cvs-module" and
  .intent.source.tag == "LEGACY_CVS_TAG" and
  .intent.source.dir == "legacy-cvs-module"
' >/dev/null

printf '%s' "${surface_output}" | jq -e '
  .validation.schema == "moonstone:luarocks-validation:v1" and
  .validation.rockspec_format == "3.1" and
  .validation.valid == true
' >/dev/null

echo "━━━ ✓ LuaRocks upstream bridge corpus passed (${UPSTREAM_REVISION:0:12}) ━━━"
