#!/usr/bin/env bash
set -euo pipefail

MOON_BIN="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/zig-out/bin/moon"

WORKDIR="$(mktemp -d /tmp/moonstone-link-transitive.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/child-link/src" "$WORKDIR/child-path/src" "$WORKDIR/parent/src" "$WORKDIR/app"

cat > "$WORKDIR/child-link/moonstone.toml" <<'TOML'
[package]
name = "hyg-child-link"
version = "0.1.0"
kind = "lib"

[runtime]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies.runtime]
TOML
cat > "$WORKDIR/child-link/src/hyg_child_link.lua" <<'LUA'
return { value = "linked-child" }
LUA

cat > "$WORKDIR/child-path/moonstone.toml" <<'TOML'
[package]
name = "hyg-child-path"
version = "0.1.0"
kind = "lib"

[runtime]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies.runtime]
TOML
cat > "$WORKDIR/child-path/src/hyg_child_path.lua" <<'LUA'
return { value = "path-child" }
LUA

cat > "$WORKDIR/parent/moonstone.toml" <<'TOML'
[package]
name = "hyg-parent"
version = "0.1.0"
kind = "lib"

[runtime]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies.runtime]
"hyg-child-link" = "link:hyg-child-link"
"hyg-child-path" = "path:../child-path"
TOML
cat > "$WORKDIR/parent/src/hyg_parent.lua" <<'LUA'
local linked = require("hyg_child_link")
local by_path = require("hyg_child_path")
return { value = linked.value .. "+" .. by_path.value }
LUA

(cd "$WORKDIR/child-link" && "$MOON_BIN" link)
(cd "$WORKDIR/parent" && "$MOON_BIN" link)
(cd "$WORKDIR/app" && "$MOON_BIN" init . --name hyg-app --no-git --no-sync && "$MOON_BIN" use lua@5.4 --no-sync && "$MOON_BIN" add link:hyg-parent)

test -L "$WORKDIR/app/.moonstone/env/share/lua/5.4/hyg_parent.lua"
test -L "$WORKDIR/app/.moonstone/env/share/lua/5.4/hyg_child_link.lua"
test -L "$WORKDIR/app/.moonstone/env/share/lua/5.4/hyg_child_path.lua"
(cd "$WORKDIR/app" && "$MOON_BIN" exec -- lua -e 'print(require("hyg_parent").value)') | grep 'linked-child+path-child'
