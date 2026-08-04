#!/usr/bin/env bash
set -euo pipefail

# Test: top-level -C / --directory changes project resolution without leaking
# into child command arguments or requiring the caller to change directories.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"
WORKDIR="$(mktemp -d /tmp/moonstone-directory-option.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "$WORKDIR/project"
cat > "$WORKDIR/project/moonstone.toml" <<'TOML'
manifest_version = 2

[package]
name = "directory-option-test"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[scripts]
check = "lua scripts/check.lua"
TOML

"$MOON_BIN" -C "$WORKDIR/project" manifest export --json | grep -q '"name":"directory-option-test"'
"$MOON_BIN" --directory="$WORKDIR/project" manifest script list --json | grep -q '"name":"check"'

echo "━━━ ✓ global directory option passed ━━━"
