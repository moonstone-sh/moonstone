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
  echo "ERROR: LuaJIT or Lua is required for projection parity checks." >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/moonstone-rockspec-projection.XXXXXX")"
trap 'rm -rf "${work_dir}"' EXIT

platform_config() {
  local platform="$1"
  case "${platform}" in
    linux) printf '%s\n' 'platforms = { "unix", "linux" }' ;;
    macosx) printf '%s\n' 'platforms = { "unix", "macosx" }' ;;
    win32) printf '%s\n' 'platforms = { "windows", "win32" }' ;;
    *) echo "ERROR: unsupported projection platform: ${platform}" >&2; exit 64 ;;
  esac
}

platforms=(linux macosx win32)
case_count=0

while IFS= read -r fixture; do
  for platform in "${platforms[@]}"; do
    config_path="${work_dir}/${platform}.lua"
    platform_config "${platform}" > "${config_path}"

    upstream="$({
      LUAROCKS_CONFIG="${config_path}" HOME="${work_dir}" \
        "${LUA_BIN}" "${CORPUS_DIR}/upstream_projection_check.lua" \
        "${LUAROCKS_UPSTREAM_DIR}" "${CORPUS_DIR}/${fixture}" "${work_dir}"
    } | jq -S -c '.')"
    moonstone="$({
      "${LUA_BIN}" "${PROJECT_ROOT}/src/core/luarocks/bridge.lua" "${CORPUS_DIR}/${fixture}" "${platform}"
    } | jq -S -c '
      .intent | {
        source: (.source | del(.file)),
        dependencies,
        build_dependencies,
        test_dependencies,
        external_dependencies,
        build,
        hooks,
        test
      } | with_entries(select(.value != null))
    ')"

    if [[ "${moonstone}" != "${upstream}" ]]; then
      echo "ERROR: Moonstone projection diverged from upstream for ${fixture} on ${platform}" >&2
      echo "upstream:  ${upstream}" >&2
      echo "moonstone: ${moonstone}" >&2
      exit 1
    fi
    case_count=$((case_count + 1))
  done
done < <(awk -F '\t' '$1 == "accept" { print $2 }' "${CORPUS_DIR}/expectations.tsv")

echo "━━━ ✓ LuaRocks platform projection parity passed (${case_count} cases) ━━━"
