#!/usr/bin/env bash
set -euo pipefail

MOON_BIN="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/zig-out/bin/moon"

WORKDIR="$(mktemp -d /tmp/moonstone-live-single-file.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/single/src" "$WORKDIR/app"
cat > "$WORKDIR/single/moonstone.toml" <<'TOML'
[package]
name = "single"
version = "0.1.0"
kind = "lib"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies.runtime]
TOML
cat > "$WORKDIR/single/src/single.lua" <<'LUA'
return { value = "single-ok" }
LUA
(cd "$WORKDIR/single" && "$MOON_BIN" link)
(cd "$WORKDIR/app" && "$MOON_BIN" init . --name single-app --no-git --no-sync && "$MOON_BIN" interpreter set lua@5.4 --no-sync && "$MOON_BIN" add link:single)
test -L "$WORKDIR/app/.moonstone/env/share/lua/5.4/single.lua"
(cd "$WORKDIR/app" && "$MOON_BIN" exec -- lua -e 'print(require("single").value)') | grep 'single-ok'
