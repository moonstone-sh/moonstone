#!/usr/bin/env bash
set -euo pipefail

# Contract: a project environment projects a linked package's Lua modules as
# per-file symlinks, so `debug.getinfo(1, "S").source` reports a path inside
# the consumer's .moonstone/env. Moonstone therefore exports the package's real
# root as MOONSTONE_PACKAGE_ROOT_<NAME>, and a package can locate its own
# sibling assets through that variable without resolving symlinks itself.
#
# See docs/PROJECT_ENVIRONMENT.md.

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"

WORKDIR="$(mktemp -d /tmp/moonstone-package-root.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT

DEP="${WORKDIR}/rooted-lib"
APP="${WORKDIR}/app"
mkdir -p "${DEP}/src/rooted_lib" "${DEP}/assets" "${APP}"

cat > "${DEP}/moonstone.toml" <<'TOML'
[package]
name = "rooted-lib"
version = "0.1.0"
kind = "lib"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"
TOML

printf 'sibling asset payload\n' > "${DEP}/assets/data.txt"

# The package locates its own asset the way a real package would: through the
# root Moonstone exports, not by walking up from debug.getinfo.
cat > "${DEP}/src/rooted_lib/init.lua" <<'LUA'
local M = {}

M.own_source = debug.getinfo(1, "S").source:sub(2)
M.own_root = os.getenv("MOONSTONE_PACKAGE_ROOT_ROOTED_LIB")

function M.read_asset()
  local handle = assert(io.open(M.own_root .. "/assets/data.txt", "r"))
  local contents = handle:read("*a")
  handle:close()
  return (contents:gsub("%s+$", ""))
end

return M
LUA

(
    cd "${APP}"
    "${MOON_BIN}" init . --name rooted-app --kind script --interpreter lua@5.4 --no-git --no-sync
    "${MOON_BIN}" add path:../rooted-lib
)

cd "${APP}"

# The projection really is a symlink; this is the behavior the contract
# documents rather than a detail the test invents.
if [[ ! -L ".moonstone/env/share/lua/5.4/rooted_lib/init.lua" ]]; then
    echo "ERROR: expected a symlinked module projection" >&2
    exit 1
fi

REAL_DEP="$(cd "${DEP}" && pwd -P)"

# env.toml records the real root, and `moon env` reports it.
grep -Fq "root = \"${REAL_DEP}\"" .moonstone/env/env.toml
grep -Fq 'env = "MOONSTONE_PACKAGE_ROOT_ROOTED_LIB"' .moonstone/env/env.toml
grep -Fq 'projection = "live"' .moonstone/env/env.toml
"${MOON_BIN}" env --json | grep -Fq '"env":"MOONSTONE_PACKAGE_ROOT_ROOTED_LIB"'
"${MOON_BIN}" env --shell bash | grep -Fq "export MOONSTONE_PACKAGE_ROOT_ROOTED_LIB=\"${REAL_DEP}\""

# `debug.getinfo` reports the consumer's environment, not the real package.
OWN_SOURCE="$("${MOON_BIN}" exec -- lua -e 'io.write(require("rooted_lib").own_source)')"
case "${OWN_SOURCE}" in
    *"/.moonstone/env/share/lua/"*) ;;
    *)
        echo "ERROR: expected debug.getinfo to report the projected path, got '${OWN_SOURCE}'" >&2
        exit 1
        ;;
esac

# The exported root does not, and it locates the package's sibling asset.
OWN_ROOT="$("${MOON_BIN}" exec -- lua -e 'io.write(require("rooted_lib").own_root)')"
if [[ "${OWN_ROOT}" != "${REAL_DEP}" ]]; then
    echo "ERROR: exported package root is '${OWN_ROOT}', expected '${REAL_DEP}'" >&2
    exit 1
fi

"${MOON_BIN}" exec -- lua -e 'io.write(require("rooted_lib").read_asset())' | grep -Fqx 'sibling asset payload'

# Store-backed packages get the same treatment, so a package author does not
# need to know how it was installed.
grep -Fq 'projection = "store"' .moonstone/env/env.toml

echo "━━━ ✓ package root projection contract passed ━━━"
