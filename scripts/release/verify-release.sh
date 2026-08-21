#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WITH_UPSTREAM=false
WITH_CONTRACTS=false
LUA_BIN="${LUA_BIN:-}"

usage() {
    cat <<'EOF'
Usage: scripts/release/verify-release.sh [--with-upstream] [--with-contracts]

Runs Moonstone's blocking Linux release certification matrix. `--with-upstream`
requires LUAROCKS_UPSTREAM_DIR to identify the pinned LuaRocks checkout.
`--with-contracts` runs the generated TypeScript, Go, and Lua contract checks.
EOF
}

while (($#)); do
    case "$1" in
        --with-upstream) WITH_UPSTREAM=true ;;
        --with-contracts) WITH_CONTRACTS=true ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 64
            ;;
    esac
    shift
done

run() {
    printf '\n━━━ %s ━━━\n' "$1"
    shift
    "$@"
}

cd "${ROOT_DIR}"

run "Check formatting" zig fmt --check --exclude src/core/assets/templates src/ build.zig
run "Build native target" zig build
run "Compile Windows GNU target" zig build -Dtarget=x86_64-windows-gnu
run "Run Zig tests" zig build test

if [[ "${WITH_UPSTREAM}" == true ]]; then
    : "${LUAROCKS_UPSTREAM_DIR:?--with-upstream requires LUAROCKS_UPSTREAM_DIR}"
    if [[ -z "${LUA_BIN}" ]]; then
        LUA_BIN="$(command -v lua5.4 || command -v lua || true)"
    fi
    if [[ -z "${LUA_BIN}" ]]; then
        echo "error: --with-upstream requires Lua 5.4 (lua5.4 or lua)" >&2
        exit 1
    fi
    run "Verify LuaRocks parser corpus" env LUA_BIN="${LUA_BIN}" tests/upstream/luarocks/run_conformance.sh
    run "Verify LuaRocks schema mutations" env LUA_BIN="${LUA_BIN}" tests/upstream/luarocks/run_schema_mutation_matrix.sh
    run "Verify LuaRocks platform projections" env LUA_BIN="${LUA_BIN}" tests/upstream/luarocks/run_projection_parity.sh
fi

run "Generate synthetic test sandbox" tests/run_lua_tool.sh generate-sandbox --clean
run "Build synthetic registry" tests/run_lua_tool.sh registry-builder --output-dir "${ROOT_DIR}/fixtures/sandbox"

build_contracts=(
    tests/e2e/build/make_module.sh
    tests/e2e/build/cmake_module.sh
    tests/e2e/build/luarocks_make_cmodule_contract.sh
    tests/e2e/build/luarocks_command_contract.sh
    tests/e2e/build/luarocks_build_dependencies_contract.sh
    tests/e2e/build/luarocks_cmake_contract.sh
)

for contract in "${build_contracts[@]}"; do
    run "Verify $(basename "${contract}" .sh)" env MOONSTONE_REAL_LUAROCKS=1 "${contract}"
done

real_rocks_contracts=(
    tests/e2e/resolution/cqueues_real_contract.sh
    tests/e2e/resolution/luafilesystem_real_contract.sh
    tests/e2e/resolution/luasql_sqlite3_real_contract.sh
    tests/e2e/resolution/luv_real_contract.sh
    tests/e2e/resolution/luaposix_real_contract.sh
    tests/e2e/resolution/foreign_target_pure_lua_rocks.sh
)

for contract in "${real_rocks_contracts[@]}"; do
    run "Verify $(basename "${contract}" .sh)" env MOONSTONE_REAL_LUAROCKS=1 "${contract}"
done

run "Verify materialization suite" env MOONSTONE_REAL_LUAROCKS=1 bash tests/scripts/run_tests.sh --suite materialization
run "Verify native library projection" tests/e2e/commands/native_library_projection.sh

if [[ "${WITH_CONTRACTS}" == true ]]; then
    run "Verify generated contracts" bash packages/contracts/tests/run.sh
fi

printf '\n━━━ ✓ Linux release certification passed ━━━\n'
