#!/usr/bin/env bash
set -euo pipefail

# Test: LuaRocks lock replay after the matching CAS artifact is purged.
# LuaRocks resolution owns materialization and returns an already-committed
# candidate; replay must validate that candidate without attempting a second
# store commit.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

RANDOM_PORT=$(( ( RANDOM % 1000 ) + 8300 ))
MOCK_DIR="/tmp/moonstone-mock-rocks-lock-replay"
rm -rf "${MOCK_DIR}"
cp -R "${PROJECT_ROOT}/fixtures/sandbox-reference/mock-luarocks" "${MOCK_DIR}"
perl -pi -e "s/localhost:8641/localhost:${RANDOM_PORT}/g" "${MOCK_DIR}/fakebin-1.0-1.rockspec"

python3 -m http.server "${RANDOM_PORT}" --directory "${MOCK_DIR}" >/tmp/moonstone-rocks-lock-replay-server.log 2>&1 &
MOCK_PID=$!
trap 'kill "${MOCK_PID}" 2>/dev/null || true' EXIT

export MOONSTONE_LUAROCKS_URL="http://localhost:${RANDOM_PORT}"
for _ in {1..60}; do
    if curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null

TEST_APP="${SANDBOX_DIR}/rocks-lock-replay-app"
rm -rf "${TEST_APP}"
mkdir -p "${TEST_APP}"
cd "${TEST_APP}"

echo "━━━ create lockfile for rocks:fakebin ━━━"
moon init . --name rocks-lock-replay-app --no-git
moon interpreter set lua@5.4
moon add rocks:fakebin

STORE_DIR="${MOONSTONE_DATA}/store/v0"
ARTIFACT_DIR=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "fakebin"$' {} \; | head -1 | xargs dirname)
if [[ -z "${ARTIFACT_DIR}" || ! -d "${ARTIFACT_DIR}" ]]; then
    echo "ERROR: fakebin artifact was not committed to the store"
    exit 1
fi

echo "━━━ purge fakebin artifact and project environment ━━━"
rm -rf "${ARTIFACT_DIR}" .moonstone/env

echo "━━━ replay lockfile and rematerialize fakebin ━━━"
moon sync --locked

echo "━━━ validate restored package and executable ━━━"
find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "fakebin"$' {} \; | grep -q .
moon exec -- fakebin | grep -q 'fake binary works!'

echo "━━━ ✓ LuaRocks locked replay after purge passed ━━━"
