#!/usr/bin/env bash
set -euo pipefail

# Contract: LuaRocks build_dependencies form a temporary build-only closure.
# Their artifacts are materialized before the dependent foreign build, exposed
# through that build's projected PATH, recorded in the dependent recipe, and
# never linked into the final project environment.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

case "$(uname -s)" in
    Darwin|Linux|FreeBSD) ;;
    *)
        echo "SKIP: LuaRocks build dependency fixture requires a POSIX sh host"
        exit 0
        ;;
esac

RANDOM_PORT=$(((RANDOM % 1000) + 8500))
WORKDIR="$(mktemp -d /tmp/moonstone-rockspec-build-dependencies.XXXXXX)"
MOCK_DIR="${WORKDIR}/mock-rocks"
TOOL_SOURCE="${MOCK_DIR}/build-only-tool-1.0"
PARENT_SOURCE="${MOCK_DIR}/build-dependent-rock-1.0"
INDEPENDENT_SOURCE="${MOCK_DIR}/independent-rock-1.0"
TEST_APP="${WORKDIR}/app"

cleanup() {
    kill "${MOCK_PID:-}" 2>/dev/null || true
    wait "${MOCK_PID:-}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

mkdir -p "${TOOL_SOURCE}" "${PARENT_SOURCE}" "${INDEPENDENT_SOURCE}" "${TEST_APP}"
cat > "${TOOL_SOURCE}/build-marker" <<'INNER'
#!/bin/sh
printf 'build tool was projected\n'
INNER
chmod +x "${TOOL_SOURCE}/build-marker"
cat > "${INDEPENDENT_SOURCE}/independent_rock.lua" <<'INNER'
return "independent artifact"
INNER

tar -czf "${MOCK_DIR}/build-only-tool-1.0.tar.gz" -C "${MOCK_DIR}" build-only-tool-1.0
tar -czf "${MOCK_DIR}/build-dependent-rock-1.0.tar.gz" -C "${MOCK_DIR}" build-dependent-rock-1.0
tar -czf "${MOCK_DIR}/independent-rock-1.0.tar.gz" -C "${MOCK_DIR}" independent-rock-1.0

cat > "${MOCK_DIR}/build-only-tool-1.0-1.rockspec" <<INNER
package = "build-only-tool"
version = "1.0-1"
source = { url = "http://127.0.0.1:${RANDOM_PORT}/build-only-tool-1.0.tar.gz" }
dependencies = { "lua >= 5.1" }
build = {
   type = "builtin",
   modules = {},
   install = { bin = { ["build-marker"] = "build-marker" } },
}
INNER

cat > "${MOCK_DIR}/build-dependent-rock-1.0-1.rockspec" <<INNER
rockspec_format = "3.0"
package = "build-dependent-rock"
version = "1.0-1"
source = { url = "http://127.0.0.1:${RANDOM_PORT}/build-dependent-rock-1.0.tar.gz" }
dependencies = { "lua >= 5.1" }
build_dependencies = { "build-only-tool >= 1.0" }
build = {
   type = "command",
   build_command = [[
build-marker > build-marker.txt
]],
   install_command = [[
mkdir -p "\$PREFIX/share/lua/\$LUA_ABI"
printf 'return "built with a projected tool"\n' > "\$PREFIX/share/lua/\$LUA_ABI/build_dependent_rock.lua"
]],
   install = { conf = { ["build-marker.txt"] = "build-marker.txt" } },
}
INNER

cat > "${MOCK_DIR}/independent-rock-1.0-1.rockspec" <<INNER
package = "independent-rock"
version = "1.0-1"
source = { url = "http://127.0.0.1:${RANDOM_PORT}/independent-rock-1.0.tar.gz" }
dependencies = { "lua >= 5.1" }
build = {
   type = "builtin",
   modules = { independent_rock = "independent_rock.lua" },
}
INNER

cat > "${MOCK_DIR}/manifest-5.4.json" <<'INNER'
{"repository":{"build-only-tool":{"1.0-1":[{"arch":"rockspec"}]},"build-dependent-rock":{"1.0-1":[{"arch":"rockspec"}]},"independent-rock":{"1.0-1":[{"arch":"rockspec"}]}}}
INNER

(cd "${MOCK_DIR}" && python3 -m http.server "${RANDOM_PORT}" --bind 127.0.0.1) >"${WORKDIR}/server.log" 2>&1 &
MOCK_PID=$!

export MOONSTONE_LUAROCKS_URL="http://127.0.0.1:${RANDOM_PORT}"
for _ in {1..60}; do
    if curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null 2>&1; then
        break
    fi
    if ! kill -0 "${MOCK_PID}" 2>/dev/null; then
        cat "${WORKDIR}/server.log" >&2
        exit 1
    fi
    sleep 0.5
done
curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null

cd "${TEST_APP}"
moon init . --name build-dependencies-contract --no-git --no-sync
moon interpreter set lua@5.4 --no-sync

echo "━━━ materialize the build-only closure ━━━"
if moon add rocks:build-dependent-rock --no-sync >"${WORKDIR}/no-sync.log" 2>&1; then
    echo "expected LuaRocks source add with --no-sync to fail" >&2
    exit 1
fi
grep -Fq 'require `moon sync`' "${WORKDIR}/no-sync.log"
! grep -Fq 'build-dependent-rock' moonstone.toml

cat >> moonstone.toml <<'DEPENDENCIES'

[[dependencies]]
name = "build-dependent-rock"
constraint = "*"
registry = "rocks"
role = "runtime"

[[dependencies]]
name = "independent-rock"
constraint = "*"
registry = "rocks"
role = "runtime"
DEPENDENCIES

moon sync --jobs 2 --progress plain >"${WORKDIR}/parallel.stderr" 2>&1

for package_name in build-only-tool independent-rock; do
    grep -Eq "^  materializing realize:[^:]+:rocks:${package_name}@1\.0-1: ${package_name}@1\.0-1$" "${WORKDIR}/parallel.stderr"
done
awk '
    /^  materializing realize:[^:]+:rocks:build-only-tool@1\.0-1:/ && !build_tool_started { build_tool_started = NR }
    /^  materializing realize:[^:]+:rocks:independent-rock@1\.0-1:/ && !independent_started { independent_started = NR }
    /^  completed realize:[^:]+:rocks:(build-only-tool|independent-rock)@1\.0-1:/ && !first_terminal { first_terminal = NR }
    END {
        exit !(build_tool_started && independent_started && first_terminal &&
            build_tool_started < first_terminal && independent_started < first_terminal)
    }
' "${WORKDIR}/parallel.stderr" || {
    echo "ERROR: independent Rock did not share the first materialization wave with the build dependency" >&2
    cat "${WORKDIR}/parallel.stderr" >&2
    exit 1
}

STORE_DIR="${MOONSTONE_DATA}/store/v0"
PARENT_MANIFEST="$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "build-dependent-rock"$' {} \; | head -1)"
TOOL_MANIFEST="$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "build-only-tool"$' {} \; | head -1)"
[[ -n "${PARENT_MANIFEST}" && -f "${PARENT_MANIFEST}" ]]
[[ -n "${TOOL_MANIFEST}" && -f "${TOOL_MANIFEST}" ]]

echo "━━━ assert temporary projected build scope and final isolation ━━━"
grep -Fq 'build tool was projected' "$(dirname "${PARENT_MANIFEST}")/files/assets/conf/build-marker.txt"
moon exec -- lua -e 'print(require("build_dependent_rock"))' | grep -q 'built with a projected tool'
[[ ! -e ".moonstone/env/bin/build-marker" ]]
grep -A 30 'name = "build-only-tool"' moonstone.lock | grep -q '^roles = \["build"\]$'

echo "━━━ assert recipe identity records the build closure ━━━"
grep -q '^recipe_hash = "b3:' "${PARENT_MANIFEST}"

echo "━━━ replay the locked build closure ━━━"
rm -rf .moonstone/env
moon sync --locked
moon exec -- lua -e 'print(require("build_dependent_rock"))' | grep -q 'built with a projected tool'
[[ ! -e ".moonstone/env/bin/build-marker" ]]

echo "━━━ ✓ LuaRocks build dependency scope contract passed ━━━"
