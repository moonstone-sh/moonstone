#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CORPUS_DIR="${PROJECT_ROOT}/tests/upstream/luarocks"
LUA_BIN="${LUA_BIN:-$(command -v luajit || command -v lua || true)}"

if [[ -z "${LUAROCKS_UPSTREAM_DIR:-}" ]]; then
  echo "ERROR: LUAROCKS_UPSTREAM_DIR must point to the pinned LuaRocks checkout." >&2
  exit 64
fi

if [[ -z "${LUA_BIN}" ]]; then
  echo "ERROR: LuaJIT or Lua is required for the schema mutation matrix." >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/moonstone-rockspec-schema.XXXXXX")"
trap 'rm -rf "${work_dir}"' EXIT

upstream_status() {
  local fixture="$1"
  local status
  if "${LUA_BIN}" "${CORPUS_DIR}/upstream_schema_check.lua" "${LUAROCKS_UPSTREAM_DIR}" "${fixture}" >/dev/null 2>&1; then
    printf '%s' accept
    return
  else
    status=$?
  fi

  case "${status}" in
    2|3) printf '%s' reject ;;
    *) printf '%s' failure ;;
  esac
}

moonstone_status() {
  local fixture="$1"
  if "${LUA_BIN}" "${PROJECT_ROOT}/src/core/luarocks/bridge.lua" "${fixture}" >/dev/null 2>&1; then
    printf '%s' accept
  else
    printf '%s' reject
  fi
}

case_count=0
while IFS=$'\t' read -r name expected fixture; do
  upstream="$(upstream_status "${fixture}")"
  moonstone="$(moonstone_status "${fixture}")"

  if [[ "${upstream}" == failure ]]; then
    echo "ERROR: upstream LuaRocks probe failed unexpectedly for ${name}" >&2
    exit 1
  fi
  if [[ "${upstream}" != "${expected}" ]]; then
    echo "ERROR: generated case ${name} expected ${expected}, but upstream returned ${upstream}" >&2
    exit 1
  fi
  if [[ "${moonstone}" != "${upstream}" ]]; then
    echo "ERROR: Moonstone diverged from upstream for ${name}: upstream=${upstream}, moonstone=${moonstone}" >&2
    exit 1
  fi
  case_count=$((case_count + 1))
done < <("${LUA_BIN}" "${CORPUS_DIR}/schema_mutation_matrix.lua" "${work_dir}")

echo "━━━ ✓ LuaRocks schema mutation matrix passed (${case_count} cases) ━━━"
