#!/usr/bin/env bash
set -euo pipefail

MOON_BIN="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}/zig-out/bin/moon"

WORKDIR="$(mktemp -d /tmp/moonstone-link-abi-tool-role.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/linked/src" "$WORKDIR/app"

cat >"$WORKDIR/linked/moonstone.toml" <<'TOML'
manifest_version = 2

[package]
name = "hyg-tool-mismatch"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.1"
abi = "5.1"

[scripts]
hello = 'lua -e "print(\"hello\")"'
TOML

cat >"$WORKDIR/linked/src/hyg_tool_mismatch.lua" <<'LUA'
return true
LUA

(cd "$WORKDIR/linked" && "$MOON_BIN" link)
(cd "$WORKDIR/app" && "$MOON_BIN" init . --name hyg-tool-app --no-git --no-sync && "$MOON_BIN" interpreter set lua@5.4 --no-sync)

# 1. --tool should succeed despite ABI mismatch
if ! (cd "$WORKDIR/app" && "$MOON_BIN" add --tool link:hyg-tool-mismatch >"$WORKDIR/tool-output" 2>&1); then
  echo "expected --tool to succeed for script package with ABI mismatch" &>2
  cat "$WORKDIR/tool-output" &>2
  exit 1
fi

# 2. --dev should fail and recommend --tool
if (cd "$WORKDIR/app" && "$MOON_BIN" add --dev link:hyg-tool-mismatch >"$WORKDIR/dev-output" 2>&1); then
  echo "expected --dev to fail for script package with ABI mismatch" &>2
  exit 1
fi
grep 'If this is a development CLI tool, add it with --tool instead.' "$WORKDIR/dev-output"

# 3. sync with --tool in manifest should also succeed
cat >"$WORKDIR/app/moonstone.toml" <<'TOML'
[package]
name = "hyg-tool-app"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies.dev]
"hyg-tool-mismatch" = "link:hyg-tool-mismatch"
TOML

if (cd "$WORKDIR/app" && "$MOON_BIN" sync >"$WORKDIR/sync-output" 2>&1); then
  echo "expected sync with dev dependency to fail for script package with ABI mismatch" &>2
  exit 1
fi
grep 'If this is a development CLI tool, add it with --tool instead.' "$WORKDIR/sync-output"

# 4. sync with tool dependency should succeed
cat >"$WORKDIR/app/moonstone.toml" <<'TOML'
[package]
name = "hyg-tool-app"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies.tool]
"hyg-tool-mismatch" = "link:hyg-tool-mismatch"
TOML

if ! (cd "$WORKDIR/app" && "$MOON_BIN" sync >"$WORKDIR/sync-tool-output" 2>&1); then
  echo "expected sync with tool dependency to succeed" &>2
  cat "$WORKDIR/sync-tool-output" &>2
  exit 1
fi

# 5. Verify that tool lua modules are linked to share/lua for LSP completions
if ! [ -L "$WORKDIR/app/.moonstone/env/share/lua/5.4/hyg_tool_mismatch.lua" ]; then
  echo "expected hyg_tool_mismatch.lua to be linked in share/lua/5.4/" &>2
  ls -la "$WORKDIR/app/.moonstone/env/share/lua/5.4/" &>2
  exit 1
fi
