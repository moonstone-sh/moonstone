#!/usr/bin/env bash
set -uo pipefail

# This script runs synthetic scenario tests from the tests/e2e/ directory.
# Pinned upstream LuaRocks contracts remain opt-in because they fetch official
# release bytes and require host-native build prerequisites.

# Since this script is now in tests/scripts/, the project root is two levels up
export PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS_DIR="${PROJECT_ROOT}/tests/e2e"
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"
SANDBOX_DIR="${PROJECT_ROOT}/fixtures/sandbox"

SUITE=""
INCLUDE_REAL_ROCKS=false

usage() {
    cat <<'USAGE'
Usage: tests/scripts/run_tests.sh [--suite <suite_name> | --all] [--include-real-rocks]

Runs isolated Moonstone E2E suites. By default, tests that download pinned
upstream LuaRocks releases are skipped. Pass --include-real-rocks to opt into
those network and native-toolchain contracts.
USAGE
}

while (($#)); do
    case "$1" in
        --suite)
            SUITE="${2:-}"
            if [[ -z "${SUITE}" ]]; then
                usage >&2
                exit 64
            fi
            shift 2
            ;;
        --all)
            shift
            ;;
        --include-real-rocks)
            INCLUDE_REAL_ROCKS=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 64
            ;;
    esac
done

PASS=0
FAIL=0
SKIP=0

is_real_rocks_contract() {
    case "$(basename "$1")" in
        cqueues_real_contract.sh|luafilesystem_real_contract.sh|luajit_real_luarocks_http_api.sh|luaposix_real_contract.sh|luasql_sqlite3_real_contract.sh|luv_real_contract.sh)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

run_test_file() {
    local test_file="$1"
    local suite_name="$2"
    local label=$(basename "${test_file}")

    if [[ "${INCLUDE_REAL_ROCKS}" != true ]] && is_real_rocks_contract "${test_file}"; then
        echo "  - ${label} skipped (use --include-real-rocks to run pinned upstream contracts)"
        ((SKIP+=1))
        return
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Running Test: [${suite_name}] ${label}"
    echo "═══════════════════════════════════════════════════════════════════"
    
    if (
        source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
        export PATH="${MOON_BIN%/*}:${PATH}"
        export SANDBOX_DIR
        if [[ "${INCLUDE_REAL_ROCKS}" == true ]]; then
            export MOONSTONE_REAL_LUAROCKS=1
        else
            export MOONSTONE_REAL_LUAROCKS=0
        fi
        bash "${test_file}"
    ); then
        echo "  ✓ ${label} passed"
        ((PASS+=1))
    else
        echo "  ✗ ${label} failed"
        ((FAIL+=1))
    fi
}

# 2. Iterate and run
if [[ -n "${SUITE}" ]]; then
    TARGET_DIR="${TESTS_DIR}/${SUITE}"
    if [[ ! -d "${TARGET_DIR}" ]]; then
        echo "Error: Suite '${SUITE}' not found at ${TARGET_DIR}"
        exit 1
    fi
    for f in "${TARGET_DIR}"/*.sh; do
        [[ -f "$f" ]] && run_test_file "$f" "${SUITE}"
    done
else
    # Run all suites
    for suite_dir in "${TESTS_DIR}"/*; do
        if [[ -d "${suite_dir}" ]]; then
            suite_name=$(basename "${suite_dir}")
            for f in "${suite_dir}"/*.sh; do
                [[ -f "$f" ]] && run_test_file "$f" "${suite_name}"
            done
        fi
    done
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Final Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "═══════════════════════════════════════════════════════════════════"

if (( FAIL > 0 )); then
    exit 1
fi
