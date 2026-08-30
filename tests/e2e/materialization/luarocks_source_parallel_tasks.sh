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

if script --version 2>&1 | grep -q 'util-linux'; then
    COLUMNS=80 script -q -e -c 'moon sync --jobs 2 --progress fancy' "${WORKDIR}/fancy.typescript" </dev/null >/dev/null 2>&1
else
    COLUMNS=80 script -q "${WORKDIR}/fancy.typescript" moon sync --jobs 2 --progress fancy </dev/null >/dev/null 2>&1
fi
for package_name in fakebin fakealt; do
    grep -Fq "preparing: ${package_name}@1.0-1" "${WORKDIR}/fancy.typescript"
    grep -Fq "materializing: ${package_name}@1.0-1" "${WORKDIR}/fancy.typescript"
done
# The selected runtime is a real member of this target's materialization
# closure, not a hidden prelude; execution-only foreign parser/tool runtimes
# remain outside that target closure.
grep -Eq "(downloading|ready): lua@5\.4" "${WORKDIR}/fancy.typescript"
# The transcript is intentionally checked rather than a timing assumption:
# both concurrent package rows and the derived aggregate must be painted, and
# all observed frames must place their fixed package names in the same terminal
# column.  This catches arrival-order rows, variable-width bars, and autowrap.
python3 - "${WORKDIR}/fancy.typescript" <<'PY'
import re
import sys
import unicodedata

raw = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
clean = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", raw)
rows = []
for line in clean.replace("\r", "\n").splitlines():
    if re.match(r"^[✓✗!·⠋] ", line) and ("fakebin" in line or "fakealt" in line) and any(marker in line for marker in (
        "queued: fake", "preparing: fake", "materializing: fake", "%",
    )):
        rows.append(line)
if not rows:
    raise SystemExit("ERROR: fancy PTY emitted no package rows")
positions = []
for line in rows:
    package = "fakebin" if "fakebin" in line else "fakealt"
    positions.append(line.index(package))
    width = sum(2 if unicodedata.east_asian_width(c) in "WF" else 0 if unicodedata.combining(c) else 1 for c in line)
    if width > 79:
        raise SystemExit("ERROR: package progress row wrapped its 80-column PTY")
if len(set(positions)) != 1:
    raise SystemExit("ERROR: package name column jittered across concurrent frames: %r" % positions)
if "Synchronized 3 packages" not in clean:
    raise SystemExit("ERROR: fancy PTY omitted derived package aggregate")
PY

# An explicit plain request must override the pseudo-terminal selected above:
# resolver and solver callbacks may still run, but none may write repaint
# controls into the captured terminal transcript.
if script --version 2>&1 | grep -q 'util-linux'; then
    script -q -e -c 'moon sync --jobs 2 --progress plain' "${WORKDIR}/plain.typescript" </dev/null >/dev/null 2>&1
else
    script -q "${WORKDIR}/plain.typescript" moon sync --jobs 2 --progress plain </dev/null >/dev/null 2>&1
fi
if LC_ALL=C grep -q $'\033' "${WORKDIR}/plain.typescript"; then
    echo "ERROR: --progress plain emitted terminal controls under a pseudo-terminal" >&2
    cat "${WORKDIR}/plain.typescript" >&2
    exit 1
fi

# Environment-selected direct mode must be just as plain when a PTY is
# attached; it must not depend on the explicit --progress plain flag.
source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
rm -rf .moonstone
rm -f moonstone.lock
if script --version 2>&1 | grep -q 'util-linux'; then
    MOONSTONE_NO_PROGRESS=1 script -q -e -c 'moon sync --jobs 2' "${WORKDIR}/env-plain.typescript" </dev/null >/dev/null 2>&1
else
    MOONSTONE_NO_PROGRESS=1 script -q "${WORKDIR}/env-plain.typescript" moon sync --jobs 2 </dev/null >/dev/null 2>&1
fi
if LC_ALL=C grep -q $'\033' "${WORKDIR}/env-plain.typescript"; then
    echo "ERROR: MOONSTONE_NO_PROGRESS emitted terminal controls under a pseudo-terminal" >&2
    cat "${WORKDIR}/env-plain.typescript" >&2
    exit 1
fi

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
    grep -Eq "^  prepared realize:[^:]+:rocks:${package_name}@1\.0-1: ${package_name}@1\.0-1$" "${WORKDIR}/plain.stderr"
    grep -Eq "^  materializing realize:[^:]+:rocks:${package_name}@1\.0-1: ${package_name}@1\.0-1$" "${WORKDIR}/plain.stderr"
    grep -Eq "^  completed realize:[^:]+:rocks:${package_name}@1\.0-1:" "${WORKDIR}/plain.stderr"
done

awk '
    /^  prepared realize:[^:]+:rocks:fakebin@1\.0-1:/ && !fakebin_started { fakebin_started = NR }
    /^  prepared realize:[^:]+:rocks:fakealt@1\.0-1:/ && !fakealt_started { fakealt_started = NR }
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

moon sync --locked --jobs 2 --quiet >"${WORKDIR}/quiet.stdout" 2>"${WORKDIR}/quiet.stderr"
if [[ -s "${WORKDIR}/quiet.stdout" || -s "${WORKDIR}/quiet.stderr" ]]; then
    echo "ERROR: --quiet emitted lifecycle output" >&2
    cat "${WORKDIR}/quiet.stderr" >&2
    cat "${WORKDIR}/quiet.stdout" >&2
    exit 1
fi

moon sync --locked --jobs 2 --json >"${WORKDIR}/locked.ndjson"
for package_name in fakebin fakealt; do
    grep -Eq "\"task_id\":\"replay:[^\"]+:rocks:${package_name}@1\.0-1\"" "${WORKDIR}/locked.ndjson"
done
grep -q '"state":"completed"' "${WORKDIR}/locked.ndjson"

echo "━━━ ✓ parallel LuaRocks source task contract passed ━━━"
