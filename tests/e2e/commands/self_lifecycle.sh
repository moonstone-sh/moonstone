#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MOON_BIN="${MOON_BIN:-$PROJECT_ROOT/zig-out/bin/moon}"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

export MOONSTONE_HOME="$WORKDIR/moonstone-home"
mkdir -p "$MOONSTONE_HOME"

echo "━━━ 1. Testing moon self install bootstrap command generation ━━━"
OUT_LATEST=$("$MOON_BIN" self install --latest)
echo "$OUT_LATEST" | grep "curl -fsSL https://moonstone.sh/install | sh -s -- --latest"

OUT_VERSION=$("$MOON_BIN" self install --version 0.3.24)
echo "$OUT_VERSION" | grep "curl -fsSL https://moonstone.sh/install | sh -s -- --version 0.3.24"

echo "━━━ 2. Testing moon self install argument validation ━━━"
if "$MOON_BIN" self install >/dev/null 2>&1; then
    echo "Fail: Expected missing release selection error"
    exit 1
fi

if "$MOON_BIN" self install --latest --version 0.3.24 >/dev/null 2>&1; then
    echo "Fail: Expected conflicting release selection error"
    exit 1
fi

echo "━━━ 3. Testing top-level deprecated commands ━━━"
DEP_INSTALL_ERR=$("$MOON_BIN" install --latest 2>&1 || true)
echo "$DEP_INSTALL_ERR" | grep "warning: 'moon install' is deprecated. Use 'moon self install' instead."

DEP_UNINSTALL_ERR=$("$MOON_BIN" uninstall -y 2>&1 || true)
echo "$DEP_UNINSTALL_ERR" | grep "warning: 'moon uninstall' is deprecated. Use 'moon self uninstall' instead."

echo "━━━ 4. Testing store purge, cache clean, config show/reset ━━━"
"$MOON_BIN" store purge
"$MOON_BIN" cache clean
"$MOON_BIN" config show
"$MOON_BIN" config reset

echo "━━━ 5. Testing --json output mode across all commands ━━━"
"$MOON_BIN" self install --latest --json | grep '"kind":"RESULT"'
"$MOON_BIN" config show --json | grep '"kind":"RESULT"'
"$MOON_BIN" cache clean --json | grep '"kind":"RESULT"'
"$MOON_BIN" store purge --json | grep '"kind":"RESULT"'
"$MOON_BIN" config reset --json | grep '"kind":"RESULT"'
"$MOON_BIN" self uninstall -y --json | grep '"kind":"RESULT"'

echo "━━━ 6. Testing moon self uninstall -y ━━━"
UNINSTALL_OUT=$("$MOON_BIN" self uninstall -y)
echo "$UNINSTALL_OUT" | grep "Moonstone user data, store, shims, and configuration have been removed."
echo "$UNINSTALL_OUT" | grep "To complete uninstallation, remove the Moonstone binary executable manually:"

echo "All self lifecycle end-to-end tests passed."
