#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

usage() {
    cat <<'USAGE'
Usage: tests/run-real-rocks.sh

Fetches pinned official LuaRocks releases, verifies their checksums, serves
them from disposable local mirrors, then checks Moonstone materialization and
locked replay. This is intentionally opt-in: it requires network access plus
the native tools declared by each contract.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

echo "━━━ Build Moonstone ━━━"
zig build

contracts=(
    tests/e2e/resolution/cqueues_real_contract.sh
    tests/e2e/resolution/luafilesystem_real_contract.sh
    tests/e2e/resolution/luasql_sqlite3_real_contract.sh
    tests/e2e/resolution/luv_real_contract.sh
    tests/e2e/resolution/luaposix_real_contract.sh
    tests/e2e/resolution/luajit_real_luarocks_http_api.sh
)

for contract in "${contracts[@]}"; do
    printf '\n━━━ Verify %s ━━━\n' "$(basename "${contract}" .sh)"
    MOONSTONE_REAL_LUAROCKS=1 bash "${contract}"
done

echo "━━━ ✓ Real LuaRocks verification passed ━━━"
