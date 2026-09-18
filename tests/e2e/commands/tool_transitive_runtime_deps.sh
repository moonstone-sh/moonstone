#!/usr/bin/env bash
set -euo pipefail

# Test: a role="tool" dependency's OWN transitive role="runtime" dependency
# must be reachable by that tool, even when the tool's own interpreter
# matches the consuming project's exactly (so no bin-runtime isolation
# triggers) and the consuming project does NOT itself declare that library
# as a direct dependency.
#
# Regression found for real: `moon exec --global -- hydronium-create ...`
# scaffolded fine, but a scaffolded project's own `hydronium dev` (a
# role="tool" dependency of the scaffolded project) failed with
# `module 'hydronium_ink' not found` -- hydronium_ink is only a transitive
# runtime dependency of the `hydronium/cli` tool, never a direct dependency
# of the scaffolded app itself. The project's own `.moonstone/env/share/lua/`
# is built exclusively from the PROJECT's own declared dependencies, so a
# library needed only by a tool (and matching the tool's own runtime, so no
# isolation ever kicked in to build it a scope either) was invisible.
#
# This also exercises linker.zig's provisionModuleRoot fix: this fixture's
# lua_module provision deliberately sets `name` identical to `path` (already
# a slash-and-extension file path, not a dotted Lua require-name) -- exactly
# how ballad's `convention.tree` collector publishes several real hydronium/*
# packages. Before that fix, provisionModuleRoot silently dropped every such
# provision (dotted-name suffix stripping mangled the extension), so the
# closure it feeds would have been empty even with the scope-creation half
# of this fix alone.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"

WORKDIR="$(mktemp -d /tmp/moonstone-tool-transitive-runtime-deps.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT
REGISTRY="${WORKDIR}/registry"
PROJECT="${WORKDIR}/project"

"${MOON_BIN}" registry create "${REGISTRY}" local

# --- example/greeter-lib: a pure-Lua library, published with `name` equal
# to `path` in its lua_module provision -- the exact shape that broke
# provisionModuleRoot.
mkdir -p "${WORKDIR}/lib-pkg"
mkdir -p "${WORKDIR}/lib-src/greeter_lib"
cat > "${WORKDIR}/lib-src/greeter_lib/init.lua" <<'LUA'
return { greet = function() return "hello from greeter_lib" end }
LUA
tar -czf "${WORKDIR}/lib-pkg/blob.tar.gz" -C "${WORKDIR}/lib-src" .

cat > "${WORKDIR}/lib-pkg/package.toml" <<'EOF'
[package]
name = "example/greeter-lib"
version = "1.0.0"
kind = "lib"

[[artifacts]]
id = "source"
kind = "source"
target = "source"
format = "tar.gz"
url = "placeholder.tar.gz"
hash = "b3:placeholder"

[artifacts.materialize]
type = "archive"

[[artifacts.provides]]
kind = "lua_module"
name = "greeter_lib/init.lua"
path = "greeter_lib/init.lua"
EOF

"${MOON_BIN}" registry push "${REGISTRY}" --descriptor "${WORKDIR}/lib-pkg/package.toml" --blob "${WORKDIR}/lib-pkg/blob.tar.gz"

# --- example/greeter-tool: a "bin" package depending on greeter-lib
# (role=runtime), whose own entry point requires it.
mkdir -p "${WORKDIR}/tool-pkg"
mkdir -p "${WORKDIR}/tool-src/bin"
cat > "${WORKDIR}/tool-src/bin/greeter-tool.lua" <<'LUA'
#!/usr/bin/env lua
print(require("greeter_lib").greet())
LUA
chmod +x "${WORKDIR}/tool-src/bin/greeter-tool.lua"
tar -czf "${WORKDIR}/tool-pkg/blob.tar.gz" -C "${WORKDIR}/tool-src" .

cat > "${WORKDIR}/tool-pkg/package.toml" <<'EOF'
[package]
name = "example/greeter-tool"
version = "1.0.0"
kind = "bin"

[[artifacts]]
id = "source"
kind = "source"
target = "any"
format = "tar.gz"
url = "placeholder.tar.gz"
hash = "b3:placeholder"
runtime = "lua@5.4.7"
lua_abi = "lua54"
lua_api = "lua-5.4"

[artifacts.materialize]
type = "archive"

[[artifacts.provides]]
kind = "bin_lua"
name = "greeter-tool"
path = "bin/greeter-tool.lua"

[[dependencies]]
name = "example/greeter-lib"
constraint = "^1.0.0"
role = "runtime"
EOF

"${MOON_BIN}" registry push "${REGISTRY}" --descriptor "${WORKDIR}/tool-pkg/package.toml" --blob "${WORKDIR}/tool-pkg/blob.tar.gz"

# The consuming project: SAME interpreter as greeter-tool declares (lua@5.4.7)
# -- no runtime mismatch, so bin-runtime isolation must NOT trigger -- and it
# does NOT itself depend on greeter-lib at all.
mkdir -p "${PROJECT}"
(cd "${PROJECT}" && "${MOON_BIN}" init . --name tool-transitive-deps-app --no-git --no-sync)
(cd "${PROJECT}" && "${MOON_BIN}" interpreter set lua@5.4.7 --no-sync)
(cd "${PROJECT}" && "${MOON_BIN}" registry add local "file://${REGISTRY}")
(cd "${PROJECT}" && "${MOON_BIN}" add "local:example/greeter-tool@1.0.0" --tool --jobs 1)

if ! grep -q 'name = "example/greeter-lib"' "${PROJECT}/moonstone.lock"; then
    echo "Fail: expected greeter-tool's transitive greeter-lib dependency to be locked" >&2
    exit 1
fi

# No isolation: runtimes match, so bin-runtime must stay empty for this tool.
if [[ -e "${PROJECT}/.moonstone/env/bin-runtime/greeter-tool" ]]; then
    echo "Fail: expected no bin-runtime scope for greeter-tool (runtimes match, not isolated)" >&2
    exit 1
fi

# The transitive closure must still be reachable via a bin-deps scope.
BIN_DEPS_ENV="${PROJECT}/.moonstone/env/bin-deps/greeter-tool/env.toml"
if [[ ! -f "${BIN_DEPS_ENV}" ]]; then
    echo "Fail: expected ${BIN_DEPS_ENV} to exist" >&2
    exit 1
fi
if ! grep -q "greeter-lib" "${BIN_DEPS_ENV}"; then
    echo "Fail: expected ${BIN_DEPS_ENV} to reference greeter-lib's materialized path" >&2
    cat "${BIN_DEPS_ENV}" >&2
    exit 1
fi

# End to end: actually running the tool must resolve require("greeter_lib").
OUTPUT="$(cd "${PROJECT}" && "${MOON_BIN}" exec --dev -- greeter-tool)"
if [[ "${OUTPUT}" != "hello from greeter_lib" ]]; then
    echo "Fail: expected greeter-tool to print 'hello from greeter_lib', got: ${OUTPUT}" >&2
    exit 1
fi

echo "━━━ ✓ tool transitive runtime dependency test passed ━━━"
