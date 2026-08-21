#!/usr/bin/env bash
set -euo pipefail

# Contract: foreign profiles may resolve and materialize pure-Lua LuaRocks
# sources when the target runtime is an artifact and a matching host runtime
# exists solely to evaluate rockspec metadata. The foreign runtime below exits
# 99 if executed, proving Moonstone never runs it while constructing the
# profile.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

if [[ -n "${MOONSTONE_FOREIGN_TARGET:-}" ]]; then
    TARGET="${MOONSTONE_FOREIGN_TARGET}"
    case "${TARGET}" in
        *-windows-*) BRANCH="windows" ;;
        *-linux-*|*-macos|*-freebsd) BRANCH="unix" ;;
        *) echo "SKIP: unsupported foreign target ${TARGET}"; exit 0 ;;
    esac
else
    case "$(uname -s)" in
        Darwin) TARGET="x86_64-linux-gnu"; BRANCH="unix" ;;
        Linux) TARGET="x86_64-windows-gnu"; BRANCH="windows" ;;
        *) echo "SKIP: unsupported host platform"; exit 0 ;;
    esac
fi

WORKDIR="$(mktemp -d /tmp/moonstone-foreign-pure-lua.XXXXXX)"
REGISTRY="${WORKDIR}/registry"
MIRROR="${WORKDIR}/rocks"
APP="${WORKDIR}/app"
PORT=$(((RANDOM % 1000) + 10800))
cleanup() {
    kill "${SERVER_PID:-}" 2>/dev/null || true
    wait "${SERVER_PID:-}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

cp -R "${SANDBOX_DIR}/registry" "${REGISTRY}"
export MOONSTONE_REGISTRY_PATH="${REGISTRY}"
mkdir -p "${WORKDIR}/runtime/files/bin" "${MIRROR}" "${APP}"

printf '#!/bin/sh\necho foreign runtime must not execute\nexit 99\n' > "${WORKDIR}/runtime/files/bin/lua"
chmod +x "${WORKDIR}/runtime/files/bin/lua"
tar -czf "${WORKDIR}/foreign-runtime.tar.gz" -C "${WORKDIR}/runtime" .

cat > "${WORKDIR}/foreign-runtime.toml" <<EOF
[package]
name = "lua"
version = "5.4.7"
kind = "runtime"

[[artifacts]]
kind = "compiled"
target = "${TARGET}"
lua_abi = "lua-5.4"
runtime = "lua@5.4.7"
url = "placeholder"
hash = "b3:placeholder"
format = "tar.gz"
bytes = 1

[artifacts.materialize]
type = "archive"

[[artifacts.provides]]
kind = "runtime"
name = "lua"
version = "5.4.7"
lua_abi = "lua-5.4"

[[artifacts.provides]]
kind = "bin"
name = "lua"
path = "bin/lua"
EOF

cp "${REGISTRY}/packages/lua/5.4.7/package.toml" "${WORKDIR}/host-runtime.toml"
WORKDIR="${WORKDIR}" python3 - <<'PY'
import os
from pathlib import Path

workdir = Path(os.environ["WORKDIR"])
host = (workdir / "host-runtime.toml").read_text()
foreign = (workdir / "foreign-runtime.toml").read_text()
foreign_header, foreign_artifact = foreign.split("[[artifacts]]", 1)
host_artifact = host[host.index("[[artifacts]]"):]
(workdir / "combined-runtime.toml").write_text(
    foreign_header.rstrip()
    + "\n\n[[artifacts]]"
    + foreign_artifact.rstrip()
    + "\n\n"
    + host_artifact
)
PY
"${MOON_BIN}" registry push "${REGISTRY}" --descriptor "${WORKDIR}/combined-runtime.toml" --blob "${WORKDIR}/foreign-runtime.tar.gz" --replace --yes
grep -q '^name = "lua"$' "${REGISTRY}/index.toml"

make_rock() {
    local name="$1"
    local module="$2"
    local body="$3"
    local deps="$4"
    mkdir -p "${WORKDIR}/${name}-1.0/foreign"
    printf '%s\n' "${body}" > "${WORKDIR}/${name}-1.0/foreign/${module}.lua"
    cat > "${MIRROR}/${name}-1.0-1.rockspec" <<EOF
rockspec_format = "3.1"
package = "${name}"
version = "1.0-1"
source = { url = "http://127.0.0.1:${PORT}/${name}-1.0.tar.gz", dir = "${name}-1.0" }
dependencies = ${deps}
build = { type = "builtin", modules = { ["foreign.${module}"] = "foreign/${module}.lua" } }
EOF
    tar -czf "${MIRROR}/${name}-1.0.tar.gz" -C "${WORKDIR}" "${name}-1.0"
}

make_rock foreign-base base 'return "base"' '{ "lua >= 5.1" }'
make_rock foreign-unix unix 'return "unix"' '{ "lua >= 5.1" }'
make_rock foreign-windows windows 'return "windows"' '{ "lua >= 5.1" }'
mkdir -p "${WORKDIR}/foreign-native-1.0/foreign"
cat > "${WORKDIR}/foreign-native-1.0/foreign/native.c" <<'EOF'
#include <lua.h>

int luaopen_foreign_native(lua_State *state) {
    lua_pushboolean(state, 1);
    return 1;
}
EOF
cat > "${MIRROR}/foreign-native-1.0-1.rockspec" <<EOF
rockspec_format = "3.1"
package = "foreign-native"
version = "1.0-1"
source = { url = "http://127.0.0.1:${PORT}/foreign-native-1.0.tar.gz", dir = "foreign-native-1.0" }
dependencies = { "lua >= 5.1" }
build = { type = "builtin", modules = { ["foreign.native"] = "foreign/native.c" } }
EOF
tar -czf "${MIRROR}/foreign-native-1.0.tar.gz" -C "${WORKDIR}" foreign-native-1.0
mkdir -p "${WORKDIR}/foreign-root-1.0/foreign"
printf 'return "root"\n' > "${WORKDIR}/foreign-root-1.0/foreign/root.lua"
cat > "${MIRROR}/foreign-root-1.0-1.rockspec" <<EOF
rockspec_format = "3.1"
package = "foreign-root"
version = "1.0-1"
source = { url = "http://127.0.0.1:${PORT}/foreign-root-1.0.tar.gz", dir = "foreign-root-1.0" }
dependencies = { "foreign-platform-default == 1.0-1", "foreign-base == 1.0-1", platforms = { unix = { "foreign-unix == 1.0-1" }, win32 = { "foreign-windows == 1.0-1" } } }
build = { type = "builtin", modules = { ["foreign.root"] = "foreign/root.lua" } }
EOF
tar -czf "${MIRROR}/foreign-root-1.0.tar.gz" -C "${WORKDIR}" foreign-root-1.0
cat > "${MIRROR}/manifest-5.4.json" <<'EOF'
{"repository":{"foreign-root":{"1.0-1":[{"arch":"rockspec"}]},"foreign-base":{"1.0-1":[{"arch":"rockspec"}]},"foreign-unix":{"1.0-1":[{"arch":"rockspec"}]},"foreign-windows":{"1.0-1":[{"arch":"rockspec"}]},"foreign-native":{"1.0-1":[{"arch":"rockspec"}]}}}
EOF

python3 -m http.server "${PORT}" --bind 127.0.0.1 --directory "${MIRROR}" >/tmp/moonstone-foreign-pure-lua-server.log 2>&1 &
SERVER_PID=$!
export MOONSTONE_LUAROCKS_URL="http://127.0.0.1:${PORT}"
for _ in {1..60}; do
    if curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null 2>&1; then break; fi
    sleep 0.5
done
curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null

mkdir -p "${WORKDIR}/foreign-parent"
tar -czf "${WORKDIR}/foreign-parent.tar.gz" -C "${WORKDIR}/foreign-parent" .
cat > "${WORKDIR}/foreign-parent.toml" <<'EOF'
[package]
name = "moonstone/foreign-parent"
version = "1.0.0"
kind = "lib"
description = "Synthetic registry package with an exact transitive LuaRocks dependency"

[[dependencies]]
name = "foreign-root"
constraint = "== 1.0-1"
registry = "rocks"
role = "runtime"

[[artifacts]]
id = "lua-module-any-lua-5.4"
kind = "lua_module"
target = "any"
lua_api = "lua-5.4"
lua_abi = "lua-5.4"
runtime = "lua@5.4.7"
format = "tar.gz"
url = "placeholder"
hash = "b3:placeholder"
bytes = 1

[artifacts.materialize]
type = "archive"
strip_components = 0
EOF
"${MOON_BIN}" registry push "${REGISTRY}" --descriptor "${WORKDIR}/foreign-parent.toml" --blob "${WORKDIR}/foreign-parent.tar.gz" --replace --yes

cd "${APP}"
"${MOON_BIN}" init . --name foreign-pure-lua --no-git --no-sync
"${MOON_BIN}" interpreter set lua@5.4.7 --no-sync
"${MOON_BIN}" add rocks:foreign-root@1.0-1
"${MOON_BIN}" sync --target "${TARGET}" --progress plain

profile_id_for_target() {
    "${MOON_BIN}" lock profile list --json | TARGET="${TARGET}" python3 -c '
import json
import os
import sys

target = os.environ["TARGET"]
for profile in json.load(sys.stdin)["profiles"]:
    if profile["target"] == target:
        print(profile["id"])
        break
else:
    raise SystemExit(f"missing lock profile for target {target}")
'
}

"${MOON_BIN}" lock profile list --json > "${WORKDIR}/profiles.json"
grep -q "${TARGET}" "${WORKDIR}/profiles.json"
"${MOON_BIN}" lock profile get "$(profile_id_for_target)" --json > "${WORKDIR}/profile.json"
grep -q 'foreign-root' "${WORKDIR}/profile.json"
grep -q 'foreign-base' "${WORKDIR}/profile.json"
grep -q "foreign-${BRANCH}" "${WORKDIR}/profile.json"
if grep -q 'foreign-platform-default' "${WORKDIR}/profile.json"; then
    echo "ERROR: platform override did not replace its array slot" >&2
    exit 1
fi
if grep -q "foreign-$( [[ "${BRANCH}" = unix ]] && echo windows || echo unix )" "${WORKDIR}/profile.json"; then
    echo "ERROR: foreign profile selected the opposite LuaRocks platform branch" >&2
    exit 1
fi
"${MOON_BIN}" lock verify --target "${TARGET}" --json | grep -q '"valid":true'

for package in foreign-root foreign-base "foreign-${BRANCH}"; do
    while IFS= read -r artifact_manifest; do
        rm -rf "$(dirname "${artifact_manifest}")"
    done < <(find "${MOONSTONE_DATA}/store/v0" -name manifest.toml -exec grep -l "^name = \"${package}\"$" {} \;)
done
"${MOON_BIN}" sync --target "${TARGET}" --locked --progress plain
"${MOON_BIN}" lock verify --target "${TARGET}" --json | grep -q '"valid":true'

TRANSITIVE_APP="${WORKDIR}/transitive-app"
mkdir -p "${TRANSITIVE_APP}"
cd "${TRANSITIVE_APP}"
"${MOON_BIN}" init . --name foreign-transitive-rocks --no-git --no-sync
"${MOON_BIN}" interpreter set lua@5.4.7 --no-sync
"${MOON_BIN}" sync --progress plain
"${MOON_BIN}" registry add local-synthetic "${REGISTRY}" --default
"${MOON_BIN}" add local-synthetic:moonstone/foreign-parent@1.0.0 --no-sync
"${MOON_BIN}" sync --target "${TARGET}" --progress plain
"${MOON_BIN}" lock profile get "$(profile_id_for_target)" --json > "${WORKDIR}/transitive-profile.json"
grep -q 'moonstone/foreign-parent' "${WORKDIR}/transitive-profile.json"
grep -q 'foreign-root' "${WORKDIR}/transitive-profile.json"
grep -q 'foreign-base' "${WORKDIR}/transitive-profile.json"
grep -q "foreign-${BRANCH}" "${WORKDIR}/transitive-profile.json"

NATIVE_APP="${WORKDIR}/native-app"
mkdir -p "${NATIVE_APP}"
cd "${NATIVE_APP}"
"${MOON_BIN}" init . --name foreign-native-rejection --no-git --no-sync
"${MOON_BIN}" interpreter set lua@5.4.7 --no-sync
cat >> moonstone.toml <<'EOF'

[[dependencies]]
name = "foreign-native"
constraint = "^1.0-1"
registry = "rocks"
role = "runtime"
EOF
if "${MOON_BIN}" sync --target "${TARGET}" --progress plain >"${WORKDIR}/foreign-native.log" 2>&1; then
    echo "ERROR: foreign target accepted a native LuaRocks source build" >&2
    exit 1
fi
grep -q 'Foreign profiles currently support pure-Lua rocks only' "${WORKDIR}/foreign-native.log"

echo "━━━ ✓ foreign pure-Lua LuaRocks target profile passed ━━━"
