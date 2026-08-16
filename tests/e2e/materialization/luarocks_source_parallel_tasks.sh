#!/usr/bin/env bash
set -euo pipefail

# Contract: independent LuaRocks source packages are prepared and materialized
# through distinct concurrent tasks. Plain output remains durable for humans;
# NDJSON retains one stable identity per task for tools.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="$(mktemp -d /tmp/moonstone-rocks-source-parallel.XXXXXX)"
MOCK_DIR="${WORKDIR}/mock-rocks"
APP_DIR="${WORKDIR}/app"
RANDOM_PORT=$(((RANDOM % 1000) + 8300))

cleanup() {
    kill "${MOCK_PID:-}" 2>/dev/null || true
    wait "${MOCK_PID:-}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
on_exit() {
    local status=$?
    if [[ "${status}" -ne 0 ]]; then
        [[ -f "${WORKDIR}/fancy.typescript" ]] && cat "${WORKDIR}/fancy.typescript" >&2
        [[ -f "${WORKDIR}/plain.stderr" ]] && cat "${WORKDIR}/plain.stderr" >&2
        [[ -f "${WORKDIR}/plain.stdout" ]] && cat "${WORKDIR}/plain.stdout" >&2
        [[ -f "${WORKDIR}/server.log" ]] && cat "${WORKDIR}/server.log" >&2
    fi
    cleanup
    exit "${status}"
}
trap on_exit EXIT

cp -R "${PROJECT_ROOT}/fixtures/sandbox-reference/mock-luarocks" "${MOCK_DIR}"
cp "${MOCK_DIR}/fakebin-1.0-1.rockspec" "${MOCK_DIR}/fakealt-1.0-1.rockspec"
cp "${MOCK_DIR}/fakebin-1.0.tar.gz" "${MOCK_DIR}/fakealt-1.0.tar.gz"
perl -0pi -e 's/package = "fakebin"/package = "fakealt"/; s/fakebin = "fake\.lua"/fakealt = "fake.lua"/' "${MOCK_DIR}/fakealt-1.0-1.rockspec"
perl -pi -e 's/fakebin-1\.0\.tar\.gz/fakealt-1.0.tar.gz/g' "${MOCK_DIR}/fakealt-1.0-1.rockspec"
perl -pi -e "s/localhost:8641/127.0.0.1:${RANDOM_PORT}/g" "${MOCK_DIR}/fakebin-1.0-1.rockspec" "${MOCK_DIR}/fakealt-1.0-1.rockspec"
cat >"${MOCK_DIR}/manifest-5.4.json" <<'MANIFEST'
{"repository":{"fakealt":{"1.0-1":[{"arch":"rockspec"}]},"fakebin":{"1.0-1":[{"arch":"rockspec"}]}}}
MANIFEST

python3 "${PROJECT_ROOT}/tests/helpers/delayed_static_server.py" \
    --directory "${MOCK_DIR}" \
    --port "${RANDOM_PORT}" \
    --delay-seconds 0.35 \
    --delay-suffix ".tar.gz" >"${WORKDIR}/server.log" 2>&1 &
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
moon init . --name rocks-source-parallel --no-git --no-sync
moon interpreter set lua@5.4 --no-sync
cat >> moonstone.toml <<'DEPENDENCIES'

[[dependencies]]
name = "fakebin"
constraint = "*"
registry = "rocks"
role = "runtime"

[[dependencies]]
name = "fakealt"
constraint = "*"
registry = "rocks"
role = "runtime"
DEPENDENCIES

if ! command -v script >/dev/null 2>&1; then
    echo "ERROR: pseudo-terminal utility 'script' is required for the fancy progress contract" >&2
    exit 1
fi
script -q "${WORKDIR}/fancy.typescript" moon sync --jobs 2 --progress fancy </dev/null >/dev/null 2>&1
for package_name in fakebin fakealt; do
    grep -Fq "preparing: ${package_name}@1.0-1" "${WORKDIR}/fancy.typescript"
    grep -Fq "materializing: ${package_name}@1.0-1" "${WORKDIR}/fancy.typescript"
done

# The fancy run intentionally populated the store. Reset the disposable
# environment, retain the project declaration, then certify the durable plain
# and NDJSON surfaces from a fresh source realization.
source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
rm -rf .moonstone
rm -f moonstone.lock

moon sync --jobs 2 --progress plain >"${WORKDIR}/plain.stdout" 2>"${WORKDIR}/plain.stderr"
if LC_ALL=C grep -q $'\033' "${WORKDIR}/plain.stderr"; then
    echo "ERROR: --progress plain emitted terminal control sequences" >&2
    cat "${WORKDIR}/plain.stderr" >&2
    exit 1
fi
for package_name in fakebin fakealt; do
    grep -Eq "^  preparing realize:[^:]+:rocks:${package_name}@1\.0-1: ${package_name}@1\.0-1$" "${WORKDIR}/plain.stderr"
    grep -Eq "^  materializing realize:[^:]+:rocks:${package_name}@1\.0-1: ${package_name}@1\.0-1$" "${WORKDIR}/plain.stderr"
    grep -Eq "^  completed realize:[^:]+:rocks:${package_name}@1\.0-1:" "${WORKDIR}/plain.stderr"
done

awk '
    /^  preparing realize:[^:]+:rocks:fakebin@1\.0-1:/ && !fakebin_started { fakebin_started = NR }
    /^  preparing realize:[^:]+:rocks:fakealt@1\.0-1:/ && !fakealt_started { fakealt_started = NR }
    /^  (completed|failed) realize:[^:]+:rocks:(fakebin|fakealt)@1\.0-1:/ && !first_terminal { first_terminal = NR }
    END {
        exit !(fakebin_started && fakealt_started && first_terminal &&
            fakebin_started < first_terminal && fakealt_started < first_terminal)
    }
' "${WORKDIR}/plain.stderr" || {
    echo "ERROR: both Rocks must begin before the first source-rock task completes" >&2
    cat "${WORKDIR}/plain.stderr" >&2
    exit 1
}

moon sync --locked --jobs 2 --json >"${WORKDIR}/locked.ndjson"
for package_name in fakebin fakealt; do
    grep -Eq "\"task_id\":\"replay:[^\"]+:rocks:${package_name}@1\.0-1\"" "${WORKDIR}/locked.ndjson"
done
grep -q '"state":"completed"' "${WORKDIR}/locked.ndjson"

echo "━━━ ✓ parallel LuaRocks source task contract passed ━━━"
