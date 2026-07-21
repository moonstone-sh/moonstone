#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MOON_BIN="${MOON_BIN:-$PROJECT_ROOT/zig-out/bin/moon}"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

export MOONSTONE_HOME="$WORKDIR/moonstone-home"
mkdir -p "$MOONSTONE_HOME"

cp -r "$PROJECT_ROOT/examples/moonscript-ballad" "$WORKDIR/project"
cd "$WORKDIR/project"

echo "━━━ 1. Synchronizing project environment ━━━"
rm -f moonstone.lock
"$MOON_BIN" sync

echo "━━━ 2. Verifying outer moon vs inner moon resolution ━━━"
# Outer moon returns Moonstone CLI version
OUTER_VER=$("$MOON_BIN" version)
echo "$OUTER_VER" | grep -i "Moonstone"

# Inner moon returns MoonScript compiler/runner version
INNER_VER=$("$MOON_BIN" exec moon -- --version)
echo "$INNER_VER" | grep -i "MoonScript"

echo "━━━ 3. Executing MoonScript file directly ━━━"
EXEC_OUT=$("$MOON_BIN" exec moon -- src/main.moon)
echo "$EXEC_OUT" | grep "Ada Lovelace"

echo "━━━ 4. Compiling .moon to Lua and running with Lua 5.4 ━━━"
mkdir -p dist/src
"$MOON_BIN" exec moonc -- -t dist/src src/main.moon
LUA_OUT=$("$MOON_BIN" exec lua dist/src/main.lua)
echo "$LUA_OUT" | grep "Ada Lovelace"

echo "━━━ 5. Verifying Ballad export ━━━"
"$MOON_BIN" exec ballad play partiture.lua
test -f dist/src/main.lua

echo "All MoonScript coexistence end-to-end tests passed."
