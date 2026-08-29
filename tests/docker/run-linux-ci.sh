#!/usr/bin/env bash
set -euo pipefail

readonly LUAROCKS_REF="665f160b4d0b79e85e66c6cc83e442d72eb40868"
readonly LUAROCKS_DIR="/workspace/.ci/luarocks-upstream"

usage() {
    cat <<'USAGE'
Usage: tests/docker/run-linux-ci.sh [luv|native-rocks|all]

Runs Moonstone's Linux CI contracts in the container image:
  luv          Build Moonstone and execute only the pinned luv CMake contract.
  native-rocks Build Moonstone and execute the pinned upstream native-rock suite.
  all          Run the Linux release-certification matrix plus the pinned
               LuaRocks corpus. This is the default.
USAGE
}

scope="${1:-all}"
case "${scope}" in
    luv|native-rocks|all) ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac

# The Docker harness is a CI-shaped runner even when invoked manually.
export MOONSTONE_NO_PROGRESS=1

run() {
    printf '\n━━━ %s ━━━\n' "$1"
    shift
    "$@"
}

checkout_luarocks_reference() {
    rm -rf "${LUAROCKS_DIR}"
    mkdir -p "$(dirname "${LUAROCKS_DIR}")"
    git init --quiet "${LUAROCKS_DIR}"
    git -C "${LUAROCKS_DIR}" remote add origin https://github.com/luarocks/luarocks.git
    git -C "${LUAROCKS_DIR}" fetch --quiet --depth 1 origin "${LUAROCKS_REF}"
    git -C "${LUAROCKS_DIR}" checkout --quiet --detach FETCH_HEAD
}

if [[ "${scope}" != "all" ]]; then
    run "Check formatting" zig fmt --check --exclude src/core/assets/templates src/ build.zig
    run "Build Linux Moonstone" zig build
    run "Compile Windows x86_64 GNU target" zig build -Dtarget=x86_64-windows-gnu
    run "Compile Windows ARM64 GNU target" zig build -Dtarget=aarch64-windows-gnu
    run "Run Zig tests" zig build test
fi

case "${scope}" in
    luv)
        run "Verify pinned luv CMake materialization and locked replay" \
            env MOONSTONE_REAL_LUAROCKS=1 tests/e2e/resolution/luv_real_contract.sh
        ;;
    native-rocks)
        for contract in \
            tests/e2e/resolution/cqueues_real_contract.sh \
            tests/e2e/resolution/luafilesystem_real_contract.sh \
            tests/e2e/resolution/luasql_sqlite3_real_contract.sh \
            tests/e2e/resolution/luv_real_contract.sh \
            tests/e2e/resolution/luaposix_real_contract.sh; do
            run "Verify $(basename "${contract}" .sh)" \
                env MOONSTONE_REAL_LUAROCKS=1 "${contract}"
        done
        ;;
    all)
        run "Checkout pinned LuaRocks reference" checkout_luarocks_reference
        export LUAROCKS_UPSTREAM_DIR="${LUAROCKS_DIR}"
        run "Verify LuaRocks parser corpus" env LUA_BIN=lua5.4 tests/upstream/luarocks/run_conformance.sh
        run "Verify LuaRocks schema mutations" env LUA_BIN=lua5.4 tests/upstream/luarocks/run_schema_mutation_matrix.sh
        run "Verify LuaRocks platform projections" env LUA_BIN=lua5.4 tests/upstream/luarocks/run_projection_parity.sh
        run "Run Linux release certification" scripts/release/verify-release.sh --with-upstream
        ;;
esac
