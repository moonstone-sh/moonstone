#!/usr/bin/env bash
set -euo pipefail

MOON_BIN="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}/zig-out/bin/moon"

WORKDIR="$(mktemp -d /tmp/moonstone-link-abi-mismatch.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/linked/src" "$WORKDIR/app"

cat > "$WORKDIR/linked/moonstone.toml" <<'TOML'
[package]
name = "hyg-mismatch"
version = "0.1.0"
kind = "lib"

[interpreter]
name = "lua"
version = "5.5"
abi = "5.5"

[dependencies.runtime]
TOML
cat > "$WORKDIR/linked/src/hyg_mismatch.lua" <<'LUA'
return true
LUA

(cd "$WORKDIR/linked" && "$MOON_BIN" link)
(cd "$WORKDIR/app" && "$MOON_BIN" init . --name hyg-mismatch-app --no-git --no-sync && "$MOON_BIN" interpreter set lua@5.4 --no-sync)
if (cd "$WORKDIR/app" && "$MOON_BIN" add link:hyg-mismatch >"$WORKDIR/output" 2>&1); then
  echo "expected linked Lua ABI mismatch" >&2
  exit 1
fi
grep 'linked package hyg-mismatch@0.1.0 requires Lua ABI 5.5, but the root project selected ABI 5.4' "$WORKDIR/output"

cat > "$WORKDIR/app/moonstone.toml" <<'TOML'
[package]
name = "hyg-mismatch-app"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies.runtime]
"hyg-mismatch" = "link:hyg-mismatch"
TOML
if (cd "$WORKDIR/app" && "$MOON_BIN" sync >"$WORKDIR/sync-output" 2>&1); then
  echo "expected linked Lua ABI mismatch during sync" >&2
  exit 1
fi
grep 'linked package hyg-mismatch@0.1.0 requires Lua ABI 5.5, but the root project selected ABI 5.4' "$WORKDIR/sync-output"
