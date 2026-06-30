#!/usr/bin/env bash
set -euo pipefail

# Test: LuaRocks artifacts are projected from the local store case-insensitively
# - Installs fakebin from a mock LuaRocks server once
# - Creates a fresh project with the same MOONSTONE_HOME
# - Requests the same rock with different casing while the network is unavailable
# - Verifies sync resolves from the store instead of fetching LuaRocks again

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

RANDOM_PORT=$(( ( RANDOM % 1000 ) + 8300 ))
MOCK_DIR="/tmp/moonstone-mock-rocks-case-store"
rm -rf "${MOCK_DIR}"
mkdir -p "${MOCK_DIR}"
cp -R "${PROJECT_ROOT}/tests/tools/moonstone-tools/fixtures/sandbox/mock-luarocks/." "${MOCK_DIR}/"
python3 - <<PY
from pathlib import Path
path = Path("${MOCK_DIR}/fakebin-1.0-1.rockspec")
path.write_text(path.read_text().replace("localhost:8641", "127.0.0.1:${RANDOM_PORT}"))
PY

(cd "${MOCK_DIR}" && python3 -m http.server "${RANDOM_PORT}" --bind 127.0.0.1) >/tmp/moonstone-mock-rocks-case-store.log 2>&1 &
MOCK_PID=$!
trap "kill $MOCK_PID 2>/dev/null || true" EXIT

export MOONSTONE_LUAROCKS_URL="http://127.0.0.1:${RANDOM_PORT}"
for _ in {1..60}; do
    if curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null

FIRST_PROJECT="/tmp/moonstone-rocks-case-store-first"
SECOND_PROJECT="/tmp/moonstone-rocks-case-store-second"
rm -rf "${FIRST_PROJECT}" "${SECOND_PROJECT}"
mkdir -p "${FIRST_PROJECT}" "${SECOND_PROJECT}"

cd "${FIRST_PROJECT}"
moon init . --name rocks-case-store-first --interpreter lua@5.4 --no-git
moon add rocks:fakebin
moon list | grep "fakebin"

kill "${MOCK_PID}" 2>/dev/null || true
wait "${MOCK_PID}" 2>/dev/null || true
export MOONSTONE_LUAROCKS_URL="http://127.0.0.1:1"

cd "${SECOND_PROJECT}"
moon init . --name rocks-case-store-second --interpreter lua@5.4 --no-sync --no-git
cat >> moonstone.toml <<'TOML'

[[dependencies]]
name = "FakeBin"
constraint = "^1.0-1"
resolver = "rocks"
role = "dependency"
TOML

moon sync
moon list | grep "fakebin\|FakeBin"
