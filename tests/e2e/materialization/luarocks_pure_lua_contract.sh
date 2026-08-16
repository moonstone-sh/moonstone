#!/usr/bin/env bash
set -euo pipefail

# Contract: a builtin LuaRocks source rock materializes its declared Lua module
# and executable as Moonstone provisions, then replays from moonstone.lock after
# both the committed artifact and project-local environment are removed.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

RANDOM_PORT=$(( ( RANDOM % 1000 ) + 8300 ))
MOCK_DIR="/tmp/moonstone-rockspec-pure-lua-contract"
TEST_APP="${SANDBOX_DIR}/rockspec-pure-lua-contract-app"

rm -rf "${MOCK_DIR}" "${TEST_APP}"
cp -R "${PROJECT_ROOT}/fixtures/sandbox-reference/mock-luarocks" "${MOCK_DIR}"

# The checked-in fixture already declares an executable Lua source. Add the
# same source as a Lua module so one compact rock proves both provision kinds.
perl -0pi -e 's/modules = \{\}/modules = { fake = "fake.lua" }/' "${MOCK_DIR}/fakebin-1.0-1.rockspec"
perl -pi -e "s/localhost:8641/localhost:${RANDOM_PORT}/g" "${MOCK_DIR}/fakebin-1.0-1.rockspec"

python3 -m http.server "${RANDOM_PORT}" --directory "${MOCK_DIR}" >/tmp/moonstone-rockspec-pure-lua-contract-server.log 2>&1 &
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

mkdir -p "${TEST_APP}"
cd "${TEST_APP}"

echo "━━━ resolve and materialize pure Lua rock ━━━"
moon init . --name rockspec-pure-lua-contract --no-git
moon interpreter set lua@5.4
moon add rocks:fakebin

STORE_DIR="${MOONSTONE_DATA}/store/v0"
ARTIFACT_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "fakebin"$' {} \; | head -1)
if [[ -z "${ARTIFACT_MANIFEST}" || ! -f "${ARTIFACT_MANIFEST}" ]]; then
    echo "ERROR: fakebin artifact manifest was not committed to the store"
    exit 1
fi
ARTIFACT_DIR="$(dirname "${ARTIFACT_MANIFEST}")"

echo "━━━ assert normalized artifact interface ━━━"
grep -q '^resolver = "rocks"$' "${ARTIFACT_MANIFEST}"
grep -q '^source_hash = "b3:' "${ARTIFACT_MANIFEST}"
grep -q '^recipe_hash = "b3:' "${ARTIFACT_MANIFEST}"
grep -q '^artifact_hash = "b3:' "${ARTIFACT_MANIFEST}"
grep -Fq 'lua_module = [{ name = "fake", path = "share/lua/5.4/fake.lua" }]' "${ARTIFACT_MANIFEST}"
grep -Fq 'bin = [{ name = "fakebin", path = "bin/fakebin" }]' "${ARTIFACT_MANIFEST}"

echo "━━━ assert projected runtime behavior ━━━"
moon exec -- lua -e 'require("fake"); print("module-visible")' | grep -q 'module-visible'
moon exec -- fakebin | grep -q 'fake binary works!'

echo "━━━ purge and replay the locked artifact contract ━━━"
rm -rf "${ARTIFACT_DIR}" .moonstone/env
moon sync --locked

RESTORED_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "fakebin"$' {} \; | head -1)
if [[ -z "${RESTORED_MANIFEST}" || ! -f "${RESTORED_MANIFEST}" ]]; then
    echo "ERROR: locked replay did not restore the fakebin artifact"
    exit 1
fi
grep -Fq 'lua_module = [{ name = "fake", path = "share/lua/5.4/fake.lua" }]' "${RESTORED_MANIFEST}"
grep -Fq 'bin = [{ name = "fakebin", path = "bin/fakebin" }]' "${RESTORED_MANIFEST}"
moon exec -- lua -e 'require("fake"); print("module-visible-after-replay")' | grep -q 'module-visible-after-replay'
moon exec -- fakebin | grep -q 'fake binary works!'

echo "━━━ ✓ LuaRocks pure-Lua artifact and replay contract passed ━━━"
