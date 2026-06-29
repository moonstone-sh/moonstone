#!/usr/bin/env bash
set -euo pipefail

# Test: Real LuaRocks + LuaJIT ABI via rocks: prefix
# - Uses a linked local LuaJIT runtime (`luajit@2.1`, ABI 5.1)
# - Pulls real LuaRocks packages using explicit `rocks:` prefixes
# - Builds a tiny HTTP JSON API using dkjson, luafilesystem, and luasocket
#
# This test reaches the public LuaRocks service, so it is opt-in to keep the
# default synthetic suite deterministic:
#   MOONSTONE_REAL_LUAROCKS=1 bash fixtures/scenario-tests/22-luajit-real-luarocks-http-api.sh

if [[ "${MOONSTONE_REAL_LUAROCKS:-0}" != "1" ]]; then
    echo "SKIP: set MOONSTONE_REAL_LUAROCKS=1 to run real LuaRocks network scenario"
    exit 0
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "SKIP: required command not found: $1"
        exit 0
    fi
}

require_cmd luajit
require_cmd curl
require_cmd zig

find_luajit_include() {
    if command -v pkg-config >/dev/null 2>&1; then
        local includedir
        includedir="$(pkg-config --variable=includedir luajit 2>/dev/null || true)"
        if [[ -n "${includedir}" && -f "${includedir}/lua.h" ]]; then
            printf '%s\n' "${includedir}"
            return 0
        fi
    fi

    for dir in \
        /opt/homebrew/include/luajit-2.1 \
        /usr/local/include/luajit-2.1 \
        /usr/include/luajit-2.1 \
        /usr/include/luajit-2.0; do
        if [[ -f "${dir}/lua.h" ]]; then
            printf '%s\n' "${dir}"
            return 0
        fi
    done

    return 1
}

LUAJIT_BIN="$(command -v luajit)"
LUAJIT_INCLUDE="$(find_luajit_include || true)"
if [[ -z "${LUAJIT_INCLUDE}" ]]; then
    echo "SKIP: LuaJIT headers not found; needed for LuaRocks C modules such as luafilesystem/luasocket"
    exit 0
fi

WORKDIR="/tmp/moonstone-real-luarocks-luajit-http-api"
PORT=$(( ( RANDOM % 1000 ) + 9100 ))
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}/luajit-runtime/files/bin" "${WORKDIR}/luajit-runtime/files/include" "${WORKDIR}/app"
export ZIG_GLOBAL_CACHE_DIR="${WORKDIR}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${WORKDIR}/zig-local-cache"
mkdir -p "${ZIG_GLOBAL_CACHE_DIR}" "${ZIG_LOCAL_CACHE_DIR}"

# Register the host LuaJIT as a local runtime link. Moonstone resolves this as
# `luajit@2.1` while LuaRocks dependency resolution uses `abi = "5.1"`.
ln -sf "${LUAJIT_BIN}" "${WORKDIR}/luajit-runtime/files/bin/lua"
for header in lua.h luaconf.h lauxlib.h lualib.h lua.hpp luajit.h; do
    if [[ -f "${LUAJIT_INCLUDE}/${header}" ]]; then
        ln -sf "${LUAJIT_INCLUDE}/${header}" "${WORKDIR}/luajit-runtime/files/include/${header}"
    fi
done
cat > "${WORKDIR}/luajit-runtime/moonstone.toml" <<'TOML'
[package]
name = "luajit"
version = "2.1.0"
kind = "runtime"

[runtime]
name = "luajit"
version = "2.1"
abi = "5.1"
TOML

cd "${WORKDIR}/luajit-runtime"
moon link

cd "${WORKDIR}/app"
moon init . --name luajit-rocks-http-api --runtime luajit@2.1 --no-sync --no-git

# Force the dependency source to the LuaRocks resolver and verify all additions
# are represented with the explicit `rocks:` prefix in moonstone.toml.
echo "━━━ add rocks:dkjson ━━━"
moon add rocks:dkjson --no-sync
echo "━━━ add rocks:luafilesystem ━━━"
moon add rocks:luafilesystem --no-sync
echo "━━━ add rocks:luasocket ━━━"
moon add rocks:luasocket --no-sync
moon sync

grep '"dkjson" = "rocks:dkjson@' moonstone.toml
grep '"luafilesystem" = "rocks:luafilesystem@' moonstone.toml
grep '"luasocket" = "rocks:luasocket@' moonstone.toml

# Live-linked runtimes are used as the build runtime but are not currently
# projected into env/bin as a runtime artifact, so expose the linked LuaJIT
# executable for this black-box API check.
ln -sf "${LUAJIT_BIN}" .moonstone/env/bin/lua

cat > server.lua <<'LUA'
local json = require("dkjson")
local lfs = require("lfs")
local socket = require("socket")

local port = tonumber(arg[1]) or error("port required")
assert(lfs.mkdir("data") or lfs.attributes("data", "mode") == "directory")

local server = assert(socket.bind("127.0.0.1", port))
server:settimeout(10)

local client = assert(server:accept())
client:settimeout(10)

local request_line = assert(client:receive("*l"))
local method, path = request_line:match("^(%S+)%s+(%S+)")
local content_length = 0
while true do
    local line = assert(client:receive("*l"))
    if line == "" then break end
    local key, value = line:match("^([^:]+):%s*(.*)$")
    if key and key:lower() == "content-length" then
        content_length = tonumber(value) or 0
    end
end

local body = content_length > 0 and assert(client:receive(content_length)) or "{}"
local payload = assert(json.decode(body))

local out = assert(io.open("data/last.json", "w"))
out:write(body)
out:close()

local response_body = assert(json.encode({
    ok = true,
    method = method,
    path = path,
    name = payload.name,
    filesystem = lfs.attributes("data/last.json", "mode"),
    runtime = jit and jit.version or _VERSION,
}))

client:send("HTTP/1.1 200 OK\r\n")
client:send("Content-Type: application/json\r\n")
client:send("Content-Length: " .. #response_body .. "\r\n")
client:send("Connection: close\r\n\r\n")
client:send(response_body)
client:close()
server:close()
LUA

moon exec -- lua server.lua "${PORT}" > server.log 2>&1 &
SERVER_PID=$!
trap 'kill ${SERVER_PID} 2>/dev/null || true' EXIT
sleep 1

response="$(curl -fsS -X POST \
    -H 'Content-Type: application/json' \
    --data '{"name":"moonstone"}' \
    "http://127.0.0.1:${PORT}/hello")"
wait "${SERVER_PID}"
trap - EXIT

printf '%s\n' "${response}"
printf '%s\n' "${response}" | grep '"ok":true'
printf '%s\n' "${response}" | grep '"name":"moonstone"'
printf '%s\n' "${response}" | grep '"filesystem":"file"'
printf '%s\n' "${response}" | grep 'LuaJIT'
grep '"name":"moonstone"' data/last.json

echo "━━━ ✓ Real LuaRocks LuaJIT HTTP API scenario passed ━━━"
