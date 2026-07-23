#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
  source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="$(mktemp -d /tmp/moonstone-link-rocks-transitive.XXXXXX)"
MOCK_DIR="${WORKDIR}/mock-rocks"
RANDOM_PORT=$(((RANDOM % 1000) + 8300))
mkdir -p "$MOCK_DIR" "$WORKDIR/parent/src" "$WORKDIR/app"

mkdir -p "$MOCK_DIR/child-1.0"
cat >"$MOCK_DIR/child-1.0/child.lua" <<'LUA'
return { hello = "from child" }
LUA
tar -czf "$MOCK_DIR/child-1.0.tar.gz" -C "$MOCK_DIR/child-1.0" .
cat >"$MOCK_DIR/child-1.0-1.rockspec" <<TOML
package = "child"
version = "1.0-1"
source = { url = "http://127.0.0.1:${RANDOM_PORT}/child-1.0.tar.gz" }
build = { type = "builtin", modules = { child = "child.lua" } }
dependencies = { "lua >= 5.1" }
TOML
cat >"$MOCK_DIR/manifest-5.4.json" <<'JSON'
{"repository":{"child":{"1.0-1":[{"arch":"rockspec"}]}}}
JSON

(cd "$MOCK_DIR" && python3 -m http.server "$RANDOM_PORT" --bind 127.0.0.1) >/tmp/moonstone-link-rocks-transitive-server.log 2>&1 &
MOCK_PID=$!
cleanup() {
  kill "$MOCK_PID" 2>/dev/null || true
  wait "$MOCK_PID" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

export MOONSTONE_LUAROCKS_URL="http://127.0.0.1:${RANDOM_PORT}"
for _ in {1..60}; do
  if curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null

cat >"$WORKDIR/parent/moonstone.toml" <<'TOML'
[package]
name = "hyg-rocks-parent"
version = "0.1.0"
kind = "lib"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies.runtime]
"child" = "rocks:child"
TOML
cat >"$WORKDIR/parent/src/hyg_rocks_parent.lua" <<'LUA'
return { child = require("child") }
LUA

(cd "$WORKDIR/parent" && "$MOON_BIN" link)
(cd "$WORKDIR/app" && "$MOON_BIN" init . --name hyg-rocks-app --no-git --no-sync && "$MOON_BIN" interpreter set lua@5.4 --no-sync && "$MOON_BIN" add link:hyg-rocks-parent)
grep 'name = "child"' "$WORKDIR/app/moonstone.lock"
(cd "$WORKDIR/app" && "$MOON_BIN" exec -- lua -e 'assert(require("hyg_rocks_parent").child ~= nil); print("rocks-child-ok")') | grep 'rocks-child-ok'
