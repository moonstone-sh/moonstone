#!/usr/bin/env bash
set -euo pipefail

# Test: LuaRocks semver and rock revision ingestion semantics
# Verifies that:
# - Constraints like `luv == 1.52.1` match compatible rock revisions (e.g. `1.52.1-0`, `1.52.1-1`)
#   and select the highest published revision (`1.52.1-1`).
# - `foo == 1.2.3` selects highest revision `1.2.3-2`.
# - `bar >= 1.2, < 2.0` selects `1.9.9-1`, while LuaRocks' pessimistic
#   `bar ~> 1.2` range is `< 1.3` and selects `1.2.0-1`.
# - Lockfile records the exact resolved artifact version/revision deterministically.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="/tmp/moonstone-e2e-luarocks-revisions"
MIRROR_DIR="${WORKDIR}/mirror"
SRC_TMP="${WORKDIR}/src_tmp"
APP_DIR="${WORKDIR}/app"
PORT=$(( ( RANDOM % 1000 ) + 9750 ))

rm -rf "${WORKDIR}"
mkdir -p "${MIRROR_DIR}" "${SRC_TMP}" "${APP_DIR}"

"${PROJECT_ROOT}/tests/run_lua_tool.sh" help >/dev/null

# 0. Create dummy source archives
cat > "${SRC_TMP}/luv.lua" <<'LUA'
return { name = "luv" }
LUA
tar -czf "${MIRROR_DIR}/luv.tar.gz" -C "${SRC_TMP}" luv.lua

cat > "${SRC_TMP}/foo.lua" <<'LUA'
return { name = "foo" }
LUA
tar -czf "${MIRROR_DIR}/foo.tar.gz" -C "${SRC_TMP}" foo.lua

cat > "${SRC_TMP}/bar.lua" <<'LUA'
return { name = "bar" }
LUA
tar -czf "${MIRROR_DIR}/bar.tar.gz" -C "${SRC_TMP}" bar.lua

cat > "${SRC_TMP}/parent.lua" <<'LUA'
return { name = "parent" }
LUA
cat > "${SRC_TMP}/high_only.lua" <<'LUA'
return { name = "high-only" }
LUA
cat > "${SRC_TMP}/low_only.lua" <<'LUA'
return { name = "low-only" }
LUA
tar -czf "${MIRROR_DIR}/parent.tar.gz" -C "${SRC_TMP}" parent.lua
tar -czf "${MIRROR_DIR}/high-only.tar.gz" -C "${SRC_TMP}" high_only.lua
tar -czf "${MIRROR_DIR}/low-only.tar.gz" -C "${SRC_TMP}" low_only.lua

# 1. Create mock rockspecs
cat > "${MIRROR_DIR}/luv-1.52.1-1.rockspec" <<ROCKSPEC
package = "luv"
version = "1.52.1-1"
source = { url = "http://127.0.0.1:${PORT}/luv.tar.gz" }
build = {
  type = "builtin",
  modules = {
    luv = "luv.lua"
  }
}
ROCKSPEC

cat > "${MIRROR_DIR}/luv-1.52.1-0.rockspec" <<ROCKSPEC
package = "luv"
version = "1.52.1-0"
source = { url = "http://127.0.0.1:${PORT}/luv.tar.gz" }
build = {
  type = "builtin",
  modules = {
    luv = "luv.lua"
  }
}
ROCKSPEC

cat > "${MIRROR_DIR}/foo-1.2.3-2.rockspec" <<ROCKSPEC
package = "foo"
version = "1.2.3-2"
source = { url = "http://127.0.0.1:${PORT}/foo.tar.gz" }
dependencies = { "high-only" }
build = {
  type = "builtin",
  modules = {
    foo = "foo.lua"
  }
}
ROCKSPEC

cat > "${MIRROR_DIR}/foo-1.2.3-0.rockspec" <<ROCKSPEC
package = "foo"
version = "1.2.3-0"
source = { url = "http://127.0.0.1:${PORT}/foo.tar.gz" }
dependencies = { "low-only" }
build = {
  type = "builtin",
  modules = { foo = "foo.lua" }
}
ROCKSPEC

cat > "${MIRROR_DIR}/parent-1.0.0-1.rockspec" <<ROCKSPEC
package = "parent"
version = "1.0.0-1"
source = { url = "http://127.0.0.1:${PORT}/parent.tar.gz" }
dependencies = { "foo == 1.2.3" }
build = {
  type = "builtin",
  modules = { parent = "parent.lua" }
}
ROCKSPEC

for marker in high-only low-only; do
  module_name="${marker//-/_}"
  cat > "${MIRROR_DIR}/${marker}-1.0.0-1.rockspec" <<ROCKSPEC
package = "${marker}"
version = "1.0.0-1"
source = { url = "http://127.0.0.1:${PORT}/${marker}.tar.gz" }
build = {
  type = "builtin",
  modules = { ["${marker}"] = "${module_name}.lua" }
}
ROCKSPEC
done

cat > "${MIRROR_DIR}/bar-1.9.9-1.rockspec" <<ROCKSPEC
package = "bar"
version = "1.9.9-1"
source = { url = "http://127.0.0.1:${PORT}/bar.tar.gz" }
build = {
  type = "builtin",
  modules = {
    bar = "bar.lua"
  }
}
ROCKSPEC

cat > "${MIRROR_DIR}/bar-1.2.0-1.rockspec" <<ROCKSPEC
package = "bar"
version = "1.2.0-1"
source = { url = "http://127.0.0.1:${PORT}/bar.tar.gz" }
build = {
  type = "builtin",
  modules = {
    bar = "bar.lua"
  }
}
ROCKSPEC

# 2. Create mock manifest
cat > "${MIRROR_DIR}/manifest-5.4.json" <<'JSON'
{
  "repository": {
    "luv": {
      "1.52.0-0": [{"arch": "rockspec"}],
      "1.52.1-0": [{"arch": "rockspec"}],
      "1.52.1-1": [{"arch": "rockspec"}],
      "1.53.0-0": [{"arch": "rockspec"}]
    },
    "foo": {
      "1.2.3-0": [{"arch": "rockspec"}],
      "1.2.3-1": [{"arch": "rockspec"}],
      "1.2.3-2": [{"arch": "rockspec"}],
      "1.2.4-0": [{"arch": "rockspec"}]
    },
    "parent": {
      "1.0.0-1": [{"arch": "rockspec"}]
    },
    "high-only": {
      "1.0.0-1": [{"arch": "rockspec"}]
    },
    "low-only": {
      "1.0.0-1": [{"arch": "rockspec"}]
    },
    "bar": {
      "1.1.9-1": [{"arch": "rockspec"}],
      "1.2.0-0": [{"arch": "rockspec"}],
      "1.2.0-1": [{"arch": "rockspec"}],
      "1.9.9-1": [{"arch": "rockspec"}],
      "2.0.0-0": [{"arch": "rockspec"}]
    }
  }
}
JSON

python3 -m http.server "${PORT}" --directory "${MIRROR_DIR}" >/tmp/moonstone-mock-revisions-server.log 2>&1 &
SERVER_PID=$!
trap 'kill "${SERVER_PID}" 2>/dev/null || true' EXIT

export MOONSTONE_LUAROCKS_URL="http://127.0.0.1:${PORT}"
for _ in {1..60}; do
    if curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

cd "${APP_DIR}"
moon init . --name test-revisions --no-git --no-sync
moon registry add local-synthetic "${SANDBOX_DIR}/registry" --default
moon interpreter set lua@5.4.7

echo "━━━ add rocks:luv@== 1.52.1 ━━━"
moon add "rocks:luv@== 1.52.1" --progress plain
grep 'name = "luv"' moonstone.lock
grep 'version = "1.52.1-1"' moonstone.lock

echo "━━━ add rocks:foo@== 1.2.3 ━━━"
moon add "rocks:parent@1.0.0-1" --progress plain
grep 'name = "parent"' moonstone.lock
grep 'name = "foo"' moonstone.lock
grep 'version = "1.2.3-2"' moonstone.lock
grep 'name = "high-only"' moonstone.lock
if grep -q 'name = "low-only"' moonstone.lock; then
  echo "ERROR: dependency metadata came from the lower foo rock revision" >&2
  exit 1
fi

echo "━━━ add rocks:bar@>= 1.2, < 2.0 ━━━"
moon add "rocks:bar@>= 1.2, < 2.0" --progress plain
grep 'name = "bar"' moonstone.lock
grep 'version = "1.9.9-1"' moonstone.lock

moon remove bar
echo "━━━ add rocks:bar@~> 1.2 ━━━"
moon add "rocks:bar@~> 1.2" --progress plain
grep 'name = "bar"' moonstone.lock
grep 'version = "1.2.0-1"' moonstone.lock

echo "━━━ verify loaded modules ━━━"
moon exec -- lua -e 'assert(require("luv").name == "luv"); assert(require("foo").name == "foo"); assert(require("bar").name == "bar"); print("ALL MODULES LOADED")' | grep "ALL MODULES LOADED"

echo "━━━ ✓ LuaRocks semver revision resolution tests passed ━━━"
