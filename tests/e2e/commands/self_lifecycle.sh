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
OUT_LATEST=$("$MOON_BIN" self update)
echo "$OUT_LATEST" | grep "curl -fsSL https://moonstone.sh/install | sh -s -- --latest"

OUT_VERSION=$("$MOON_BIN" self install --version 0.3.24)
echo "$OUT_VERSION" | grep "curl -fsSL https://moonstone.sh/install | sh -s -- --version 0.3.24"

echo "━━━ 2. Testing moon self install argument validation ━━━"
if "$MOON_BIN" self install >/dev/null 2>&1; then
    echo "Fail: Expected missing release selection error"
    exit 1
fi

if "$MOON_BIN" self update --version 0.3.24 >/dev/null 2>&1; then
    echo "Fail: Expected conflicting release selection error"
    exit 1
fi

echo "━━━ 4. Testing store purge, cache clean, config show/reset ━━━"
"$MOON_BIN" store purge
"$MOON_BIN" cache clean
"$MOON_BIN" config show
"$MOON_BIN" config reset

echo "━━━ 5. Testing --json output mode across all commands ━━━"
"$MOON_BIN" self update --json | grep '"kind":"RESULT"'
"$MOON_BIN" config show --json | grep '"kind":"RESULT"'
"$MOON_BIN" cache clean --json | grep '"kind":"RESULT"'
"$MOON_BIN" store purge --json | grep '"kind":"RESULT"'
"$MOON_BIN" config reset --json | grep '"kind":"RESULT"'
# Unsafe configured roots are refused even during preview.
printf '[paths]\nshims = "/"\n' > "$WORKDIR/unsafe.toml"
if "$MOON_BIN" --config-file "$WORKDIR/unsafe.toml" self uninstall --dry-run > "$WORKDIR/unsafe.log" 2>&1; then
    echo 'Uninstall accepted a filesystem root' >&2; exit 1
fi
grep -q UnsafeUninstallPath "$WORKDIR/unsafe.log"
# Uninstall only disposable copies, never the test runner executable.
mkdir -p "$MOONSTONE_HOME/data/store/v0" "$MOONSTONE_HOME/data/v0/shims"
printf keep > "$MOONSTONE_HOME/data/store/v0/keep"
cp "$MOON_BIN" "$WORKDIR/moon-copy"
"$WORKDIR/moon-copy" self uninstall --dry-run --json | grep '"value":"planned"'
test -x "$WORKDIR/moon-copy"
test -f "$MOONSTONE_HOME/data/store/v0/keep"
"$WORKDIR/moon-copy" self uninstall --yes --json | grep '"kind":"RESULT"'
test ! -e "$WORKDIR/moon-copy"
test -f "$MOONSTONE_HOME/data/store/v0/keep"
test ! -d "$MOONSTONE_HOME/data/v0/shims"
# Explicit purge still leaves unrelated files and project sources alone.
printf keep > "$MOONSTONE_HOME/unrelated"
cp "$MOON_BIN" "$WORKDIR/moon-copy"
"$WORKDIR/moon-copy" self uninstall --yes --purge-data --json | grep '"kind":"RESULT"'
test ! -e "$WORKDIR/moon-copy"
test ! -e "$MOONSTONE_HOME/data/store/v0/keep"
test -f "$MOONSTONE_HOME/unrelated"
echo "All self lifecycle end-to-end tests passed."
