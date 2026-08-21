#!/usr/bin/env bash
set -euo pipefail

# Contract: lock replay gives each non-link package an independent worker
# provider/SQLite connection, then merges candidates serially into the
# solution. The machine stream must retain one stable task identity per rock.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="$(mktemp -d /tmp/moonstone-locked-replay-parallel.XXXXXX)"
MOCK_DIR="${WORKDIR}/mock-rocks"
APP_DIR="${WORKDIR}/app"
RANDOM_PORT=$(((RANDOM % 1000) + 8300))

cleanup() {
    kill "${MOCK_PID:-}" 2>/dev/null || true
    wait "${MOCK_PID:-}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

cp -R "${PROJECT_ROOT}/fixtures/sandbox-reference/mock-luarocks" "${MOCK_DIR}"
cp "${MOCK_DIR}/fakebin-1.0-1.rockspec" "${MOCK_DIR}/fakealt-1.0-1.rockspec"
perl -0pi -e 's/package = "fakebin"/package = "fakealt"/; s/fakebin = "fake\.lua"/fakealt = "fake.lua"/' "${MOCK_DIR}/fakealt-1.0-1.rockspec"
perl -pi -e "s/localhost:8641/127.0.0.1:${RANDOM_PORT}/g" "${MOCK_DIR}/fakebin-1.0-1.rockspec" "${MOCK_DIR}/fakealt-1.0-1.rockspec"
cat >"${MOCK_DIR}/manifest-5.4.json" <<'EOF'
{"repository":{"fakealt":{"1.0-1":[{"arch":"rockspec"}]},"fakebin":{"1.0-1":[{"arch":"rockspec"}]}}}
EOF

(cd "${MOCK_DIR}" && python3 -m http.server "${RANDOM_PORT}" --bind 127.0.0.1) >"${WORKDIR}/server.log" 2>&1 &
MOCK_PID=$!

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
moon init . --name locked-replay-parallel --no-git --no-sync
moon registry add synthetic "${SANDBOX_DIR}/registry" --default
moon interpreter set lua@5.4 --no-sync
moon add rocks:fakebin
moon add rocks:fakealt

STORE_DIR="${MOONSTONE_DATA}/store/v0"
purge_replay_artifacts() {
    for package_name in fakebin fakealt; do
        artifact_dir=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l "^name = \"${package_name}\"\$" {} \; | head -1 | xargs dirname)
        if [[ -z "${artifact_dir}" || ! -d "${artifact_dir}" ]]; then
            echo "ERROR: ${package_name} was not materialized before replay"
            exit 1
        fi
        rm -rf "${artifact_dir}"
    done
    rm -rf .moonstone/env
}

purge_replay_artifacts
moon sync --locked --jobs 2 --progress plain >"${WORKDIR}/replay-plain.stdout" 2>"${WORKDIR}/replay-plain.stderr"
grep -Eq '^  running replay:[^:]+:rocks:fakebin@1.0-1:' "${WORKDIR}/replay-plain.stderr"
grep -Eq '^  completed replay:[^:]+:rocks:fakebin@1.0-1:' "${WORKDIR}/replay-plain.stderr"

purge_replay_artifacts
moon sync --locked --jobs 2 --json >"${WORKDIR}/replay.ndjson"
grep -Eq '"task_id":"replay:[^"]+:rocks:fakebin@1.0-1"' "${WORKDIR}/replay.ndjson"
grep -Eq '"task_id":"replay:[^"]+:rocks:fakealt@1.0-1"' "${WORKDIR}/replay.ndjson"
grep -q '"state":"completed"' "${WORKDIR}/replay.ndjson"

moon exec -- fakebin | grep -q 'fake binary works!'
moon exec -- fakealt | grep -q 'fake binary works!'

echo "━━━ ✓ parallel locked replay passed ━━━"
