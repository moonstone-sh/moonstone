#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="$(mktemp -d /tmp/moonstone-locked-hash-mismatch.XXXXXX)"
MOCK_DIR="${WORKDIR}/mock-rocks"
APP_DIR="${WORKDIR}/app"
RANDOM_PORT=$(((RANDOM % 1000) + 8300))
cp -R "${PROJECT_ROOT}/fixtures/sandbox-reference/mock-luarocks" "${MOCK_DIR}"
perl -pi -e "s/localhost:8641/127.0.0.1:${RANDOM_PORT}/g" "${MOCK_DIR}/fakebin-1.0-1.rockspec"

(cd "${MOCK_DIR}" && python3 -m http.server "${RANDOM_PORT}" --bind 127.0.0.1) >/tmp/moonstone-locked-hash-mismatch-server.log 2>&1 &
MOCK_PID=$!
cleanup() {
    kill "${MOCK_PID}" 2>/dev/null || true
    wait "${MOCK_PID}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

export MOONSTONE_LUAROCKS_URL="http://127.0.0.1:${RANDOM_PORT}"
for _ in {1..60}; do
    if curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null

mkdir -p "${APP_DIR}"
cd "${APP_DIR}"
moon init . --name locked-hash-mismatch --no-git
moon interpreter set lua@5.4
moon add rocks:fakebin

STORE_DIR="${MOONSTONE_DATA}/store/v0"
ARTIFACT_DIR=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "fakebin"$' {} \; | head -1 | xargs dirname)
if [[ -z "${ARTIFACT_DIR}" || ! -d "${ARTIFACT_DIR}" ]]; then
    echo "ERROR: fakebin artifact was not committed to the store"
    exit 1
fi

TAMPERED_HASH="b3:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
perl -0pi -e 's/(\[\[package\]\]\nname = "fakebin"[\s\S]*?artifact_hash = )"b3:[^"]+"/${1}"b3:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"/' moonstone.lock
grep -A 8 '^name = "fakebin"$' moonstone.lock | grep -q "artifact_hash = \"${TAMPERED_HASH}\""
LOCK_HASH_BEFORE=$(shasum -a 256 moonstone.lock | cut -d' ' -f1)

rm -rf "${ARTIFACT_DIR}" .moonstone/env
if moon sync >"${WORKDIR}/sync.out" 2>&1; then
    echo "ERROR: tampered lockfile unexpectedly synchronized"
    exit 1
fi

grep -q 'Locked artifact hash mismatch for fakebin@1.0-1' "${WORKDIR}/sync.out"
grep -q "Expected ${TAMPERED_HASH}" "${WORKDIR}/sync.out"
grep -q "moon sync --update" "${WORKDIR}/sync.out"
LOCK_HASH_AFTER=$(shasum -a 256 moonstone.lock | cut -d' ' -f1)
if [[ "${LOCK_HASH_BEFORE}" != "${LOCK_HASH_AFTER}" ]]; then
    echo "ERROR: failed lock replay mutated moonstone.lock"
    exit 1
fi

echo "━━━ ✓ Locked artifact hash mismatch reports exact recovery ━━━"
