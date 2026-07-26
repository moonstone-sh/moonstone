#!/usr/bin/env bash
set -euo pipefail

MOON_BIN="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}/zig-out/bin/moon"

WORKDIR="$(mktemp -d /tmp/moonstone-deep-path-closure.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/leaf/src" "$WORKDIR/middle/src" "$WORKDIR/parent/src" "$WORKDIR/app"

cat > "$WORKDIR/leaf/moonstone.toml" <<'TOML'
[package]
name = "closure-leaf"
version = "0.1.0"
kind = "lib"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"
TOML
cat > "$WORKDIR/leaf/src/closure_leaf.lua" <<'LUA'
return { value = "leaf" }
LUA

cat > "$WORKDIR/middle/moonstone.toml" <<'TOML'
[package]
name = "closure-middle"
version = "0.1.0"
kind = "lib"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies.runtime]
"closure-leaf" = "path:../leaf"
TOML
cat > "$WORKDIR/middle/src/closure_middle.lua" <<'LUA'
local leaf = require("closure_leaf")
return { value = "middle+" .. leaf.value }
LUA

cat > "$WORKDIR/parent/moonstone.toml" <<'TOML'
[package]
name = "closure-parent"
version = "0.1.0"
kind = "lib"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies.runtime]
"closure-middle" = "path:../middle"
TOML
cat > "$WORKDIR/parent/src/closure_parent.lua" <<'LUA'
local middle = require("closure_middle")
return { value = "parent+" .. middle.value }
LUA

(
    cd "$WORKDIR/app"
    "$MOON_BIN" init . --name closure-app --kind script --interpreter lua@5.4 --no-git --no-sync
    "$MOON_BIN" add path:../parent
)

test -L "$WORKDIR/app/.moonstone/env/share/lua/5.4/closure_parent.lua"
test -L "$WORKDIR/app/.moonstone/env/share/lua/5.4/closure_middle.lua"
test -L "$WORKDIR/app/.moonstone/env/share/lua/5.4/closure_leaf.lua"
(
    cd "$WORKDIR/app"
    "$MOON_BIN" exec -- lua -e 'print(require("closure_parent").value)'
) | grep -qx 'parent+middle+leaf'
