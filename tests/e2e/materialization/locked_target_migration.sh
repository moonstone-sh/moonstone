#!/usr/bin/env bash
set -euo pipefail

# Contract: new locks record a concrete host target. A legacy `native` lock
# may be refreshed by --update, but --locked must not replay it implicitly.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="$(mktemp -d /tmp/moonstone-locked-target-migration.XXXXXX)"
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
perl -pi -e "s/localhost:8641/127.0.0.1:${RANDOM_PORT}/g" "${MOCK_DIR}/fakebin-1.0-1.rockspec"
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
moon init . --name locked-target-migration --no-git --no-sync
moon interpreter set lua@5.4 --no-sync
moon add rocks:fakebin

if grep -q '^target = "native"$' moonstone.lock; then
    echo "ERROR: new lockfile retained the legacy native target"
    exit 1
fi

# Model a real pre-v3 lock rather than corrupting a v3 realization hash. v2
# package records had no semantic realization identity or target profiles.
python3 - <<'PY'
from pathlib import Path

path = Path("moonstone.lock")
before_profile, _, _ = path.read_text().partition("\n[[profile]]")
lines = []
for line in before_profile.splitlines():
    if line.startswith("realization_hash = "):
        continue
    if line == "lockfile_version = 3":
        lines.append("lockfile_version = 2")
    elif line == "[[realization]]":
        lines.append("[[package]]")
    elif line.startswith("target = "):
        lines.append('target = "native"')
    else:
        lines.append(line)
path.write_text("\n".join(lines) + "\n")
PY
LOCK_HASH_BEFORE=$(shasum -a 256 moonstone.lock | cut -d' ' -f1)

if moon sync --locked >"${WORKDIR}/locked.out" 2>&1; then
    echo "ERROR: --locked accepted a legacy native target"
    exit 1
fi
grep -q 'legacy target `native`' "${WORKDIR}/locked.out"
LOCK_HASH_AFTER=$(shasum -a 256 moonstone.lock | cut -d' ' -f1)
if [[ "${LOCK_HASH_BEFORE}" != "${LOCK_HASH_AFTER}" ]]; then
    echo "ERROR: rejected --locked replay modified moonstone.lock"
    exit 1
fi

moon sync --update
if grep -q '^target = "native"$' moonstone.lock; then
    echo "ERROR: --update did not migrate the lock target"
    exit 1
fi

moon sync --locked

HOST_TARGET=$(awk -F'"' '/^target = "/ { print $2; exit }' moonstone.lock)
moon lock profile list --json >"${WORKDIR}/profiles.json"
grep -q "${HOST_TARGET}" "${WORKDIR}/profiles.json"
moon lock verify --target "${HOST_TARGET}" --json >"${WORKDIR}/verify.json"
grep -q '"valid":true' "${WORKDIR}/verify.json"
moon lock realization list --json >"${WORKDIR}/realizations.json"
grep -q '"package":"lua"' "${WORKDIR}/realizations.json"

case "${HOST_TARGET}" in
    *-macos) FOREIGN_TARGET="x86_64-linux-gnu" ;;
    *-linux-gnu) FOREIGN_TARGET="x86_64-windows-gnu" ;;
    *) FOREIGN_TARGET="x86_64-linux-gnu" ;;
esac
ENV_HASH_BEFORE=$(find .moonstone/env -type f -exec shasum -a 256 {} + | shasum -a 256 | cut -d' ' -f1)
if moon sync --target "${FOREIGN_TARGET}" >"${WORKDIR}/foreign-target.out" 2>&1; then
    moon lock verify --target "${FOREIGN_TARGET}" --json >"${WORKDIR}/foreign-verify.json"
    grep -q '"valid":true' "${WORKDIR}/foreign-verify.json"
else
    if ! grep -Eq 'ForeignTarget(RuntimeUnavailable|SourceUnsupported)|needs a compatible runtime artifact|LuaRocks (source materialization|resolution)' "${WORKDIR}/foreign-target.out"; then
        cat "${WORKDIR}/foreign-target.out"
        exit 1
    fi
fi
ENV_HASH_AFTER=$(find .moonstone/env -type f -exec shasum -a 256 {} + | shasum -a 256 | cut -d' ' -f1)
if [[ "${ENV_HASH_BEFORE}" != "${ENV_HASH_AFTER}" ]]; then
    echo "ERROR: foreign target sync changed the host environment"
    exit 1
fi
echo "━━━ ✓ locked target migration passed ━━━"
