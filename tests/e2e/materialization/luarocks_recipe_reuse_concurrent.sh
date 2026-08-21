#!/usr/bin/env bash
set -euo pipefail

# Contract: separate Moonstone processes preparing the same deterministic
# LuaRocks artifact share one recipe lock and publish one complete CAS entry.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

RANDOM_PORT=$(((RANDOM % 1000) + 8300))
WORKDIR="$(mktemp -d /tmp/moonstone-rocks-recipe-reuse.XXXXXX)"
MOCK_DIR="${WORKDIR}/mock-rocks"
APP_A="${WORKDIR}/app-a"
APP_B="${WORKDIR}/app-b"

cp -R "${PROJECT_ROOT}/fixtures/sandbox-reference/mock-luarocks" "${MOCK_DIR}"
perl -pi -e "s/localhost:8641/localhost:${RANDOM_PORT}/g" "${MOCK_DIR}/fakebin-1.0-1.rockspec"

python3 -m http.server "${RANDOM_PORT}" --directory "${MOCK_DIR}" >/tmp/moonstone-rocks-recipe-reuse-server.log 2>&1 &
MOCK_PID=$!
cleanup() {
    kill "${MOCK_PID}" 2>/dev/null || true
    wait "${MOCK_PID}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

export MOONSTONE_LUAROCKS_URL="http://localhost:${RANDOM_PORT}"
for _ in {1..60}; do
    if curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null

prepare_app() {
    local app_path="$1"
    local app_name="$2"
    mkdir -p "${app_path}"
    (
        cd "${app_path}"
        moon init . --name "${app_name}" --no-git --no-sync
        moon registry add synthetic "${SANDBOX_DIR}/registry" --default
        moon interpreter set lua@5.4 --no-sync
        cat >> moonstone.toml <<'EOF_TOML'

[[dependencies]]
name = "fakebin"
constraint = "*"
registry = "rocks"
role = "runtime"
EOF_TOML
    )
}

prepare_app "${APP_A}" "rocks-recipe-reuse-a"
prepare_app "${APP_B}" "rocks-recipe-reuse-b"

(
    cd "${APP_A}"
    moon sync --jobs 2
) >"${WORKDIR}/app-a.log" 2>&1 &
PID_A=$!
(
    cd "${APP_B}"
    moon sync --jobs 2
) >"${WORKDIR}/app-b.log" 2>&1 &
PID_B=$!

if ! wait "${PID_A}"; then
    echo "ERROR: concurrent sync for app-a failed"
    cat "${WORKDIR}/app-a.log"
    exit 1
fi
if ! wait "${PID_B}"; then
    echo "ERROR: concurrent sync for app-b failed"
    cat "${WORKDIR}/app-b.log"
    exit 1
fi

STORE_DIR="${MOONSTONE_DATA}/store/v0"
ARTIFACT_MANIFESTS=()
while IFS= read -r artifact_manifest; do
    ARTIFACT_MANIFESTS+=("${artifact_manifest}")
done < <(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "fakebin"$' {} \;)
if [[ "${#ARTIFACT_MANIFESTS[@]}" -ne 1 ]]; then
    echo "ERROR: expected exactly one fakebin CAS artifact, found ${#ARTIFACT_MANIFESTS[@]}"
    printf '%s\n' "${ARTIFACT_MANIFESTS[@]}"
    exit 1
fi
grep -q '^recipe_hash = "b3:' "${ARTIFACT_MANIFESTS[0]}"

(
    cd "${APP_A}"
    moon exec -- fakebin
) | grep -q 'fake binary works!'
(
    cd "${APP_B}"
    moon exec -- fakebin
) | grep -q 'fake binary works!'

echo "━━━ ✓ concurrent LuaRocks recipe reuse passed ━━━"
