#!/usr/bin/env bash
set -euo pipefail

# Test: Meteorite project template lifecycle
# - Links the meteorite project into the global link store
# - Creates a project from the meteorite template
# - Syncs the environment and verifies libexec/share/bin projections
# - Generates the graph, runs dev smoke, and builds the server

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"
METEORITE_ROOT="/Users/extrordinaire/Workbench/user/meteorite"
WORKDIR="/tmp/moonstone-meteorite-template-test"

if [[ ! -x "${MOON_BIN}" ]]; then
    echo "ERROR: moon binary not found at ${MOON_BIN}; run zig build first" >&2
    exit 1
fi

# Ensure zig is available for the build script
if ! command -v zig >/dev/null 2>&1; then
    export PATH="/opt/homebrew/bin:${PATH}"
fi

rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"

echo "━━━ Link meteorite source ━━━"
cd "${METEORITE_ROOT}"
${MOON_BIN} link || true
cd "${WORKDIR}"

echo "━━━ moon init --template meteorite ━━━"
mkdir -p app
cd app
${MOON_BIN} init . --template meteorite --name meteorite-app --no-git --no-sync

echo "━━━ moon sync ━━━"
${MOON_BIN} sync

echo "━━━ Verify projected meteorite environment ━━━"
test -L .moonstone/env/libexec/meteorite
test -f .moonstone/env/libexec/meteorite/src/meteorite/init.lua
test -f .moonstone/env/libexec/meteorite/src/meteorite/cli.lua
test -f .moonstone/env/libexec/meteorite/native/src/meteorite.zig

echo "━━━ moon run generate-graph ━━━"
${MOON_BIN} run generate-graph
test -f .meteorite/graph/current/graph.zig
test -f .meteorite/graph/current/ctx.zig

echo "━━━ moon run dev (smoke) ━━━"
${MOON_BIN} run dev >/tmp/meteorite-dev-smoke.log 2>&1 &
dev_pid=$!
cleanup_dev() {
    kill -INT "${dev_pid}" 2>/dev/null || true
    wait "${dev_pid}" 2>/dev/null || true
    sh scripts/guard.sh cleanup-sessions >/dev/null 2>&1 || true
    sh scripts/guard.sh cleanup >/dev/null 2>&1 || true
}
trap cleanup_dev EXIT
for _ in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:8080/ >/tmp/meteorite-dev-root.txt 2>/tmp/meteorite-dev-root.err && \
       curl -fsS http://127.0.0.1:8080/health >/tmp/meteorite-dev-health.txt 2>/tmp/meteorite-dev-health.err; then
        break
    fi
    sleep 1
done
grep -q 'hello from meteorite-app' /tmp/meteorite-dev-root.txt
grep -q '{"ok":true}' /tmp/meteorite-dev-health.txt
cleanup_dev
trap - EXIT

echo "━━━ moon run build -- -Doptimize=ReleaseSmall ━━━"
${MOON_BIN} run build -- -Doptimize=ReleaseSmall
test -x dist/server

echo "━━━ moon run build (default) ━━━"
rm -f dist/server
${MOON_BIN} run build
test -x dist/server

echo "━━━ ✓ Meteorite template lifecycle passed ━━━"
