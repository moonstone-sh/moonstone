#!/usr/bin/env bash
set -euo pipefail

# Contract: bounded LuaRocks build.install.lib declarations become typed native
# library provisions. Shared libraries project into the runtime loader path;
# static archives remain stored but are intentionally not projected.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

case "$(uname -s)" in
    Darwin)
        SHARED_LIBRARY="libinstalllib.dylib"
        ;;
    Linux|FreeBSD)
        SHARED_LIBRARY="libinstalllib.so"
        ;;
    *)
        echo "SKIP: install.lib POSIX contract is not applicable to $(uname -s)"
        exit 0
        ;;
esac

RANDOM_PORT=$(((RANDOM % 1000) + 8700))
WORKDIR="$(mktemp -d /tmp/moonstone-rockspec-install-lib-contract.XXXXXX)"
MOCK_DIR="${WORKDIR}/mock-rocks"
KEYED_SOURCE_DIR="${MOCK_DIR}/install-lib-keyed-0.1.0"
STATIC_SOURCE_DIR="${MOCK_DIR}/install-lib-static-0.1.0"
TEST_APP="${WORKDIR}/app"

cleanup() {
    kill "${MOCK_PID:-}" 2>/dev/null || true
    wait "${MOCK_PID:-}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

mkdir -p "${KEYED_SOURCE_DIR}/src" "${KEYED_SOURCE_DIR}/native" \
    "${STATIC_SOURCE_DIR}/src" "${STATIC_SOURCE_DIR}/native" "${TEST_APP}"

cat > "${KEYED_SOURCE_DIR}/src/install_lib_keyed.lua" <<'LUA'
return "install.lib keyed contract"
LUA
printf 'shared library contract\n' > "${KEYED_SOURCE_DIR}/native/${SHARED_LIBRARY}"
tar -czf "${MOCK_DIR}/install-lib-keyed-0.1.0.tar.gz" -C "${MOCK_DIR}" install-lib-keyed-0.1.0

cat > "${STATIC_SOURCE_DIR}/src/install_lib_static.lua" <<'LUA'
return "install.lib static contract"
LUA
printf 'static archive contract\n' > "${STATIC_SOURCE_DIR}/native/libinstalllib-static.a"
tar -czf "${MOCK_DIR}/install-lib-static-0.1.0.tar.gz" -C "${MOCK_DIR}" install-lib-static-0.1.0

cat > "${MOCK_DIR}/install-lib-keyed-0.1.0-1.rockspec" <<EOF_ROCKSPEC
package = "install-lib-keyed"
version = "0.1.0-1"
source = { url = "http://127.0.0.1:${RANDOM_PORT}/install-lib-keyed-0.1.0.tar.gz" }
dependencies = { "lua >= 5.1" }
build = {
   type = "builtin",
   modules = { install_lib_keyed = "src/install_lib_keyed.lua" },
   install = {
      lib = { ["native.installlib"] = "native/${SHARED_LIBRARY}" },
   },
}
EOF_ROCKSPEC

cat > "${MOCK_DIR}/install-lib-static-0.1.0-1.rockspec" <<EOF_ROCKSPEC
package = "install-lib-static"
version = "0.1.0-1"
source = { url = "http://127.0.0.1:${RANDOM_PORT}/install-lib-static-0.1.0.tar.gz" }
dependencies = { "lua >= 5.1" }
build = {
   type = "builtin",
   modules = { install_lib_static = "src/install_lib_static.lua" },
   install = {
      lib = { "native/libinstalllib-static.a" },
   },
}
EOF_ROCKSPEC

cat > "${MOCK_DIR}/manifest-5.4.json" <<'EOF_MANIFEST'
{"repository":{"install-lib-keyed":{"0.1.0-1":[{"arch":"rockspec"}]},"install-lib-static":{"0.1.0-1":[{"arch":"rockspec"}]}}}
EOF_MANIFEST

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
moon init . --name install-lib-contract --no-git --no-sync
moon interpreter set lua@5.4 --no-sync
moon add rocks:install-lib-keyed
moon add rocks:install-lib-static

STORE_DIR="${MOONSTONE_DATA}/store/v0"
KEYED_MANIFEST="$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "install-lib-keyed"$' {} \; | head -1)"
STATIC_MANIFEST="$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "install-lib-static"$' {} \; | head -1)"
[[ -n "${KEYED_MANIFEST}" && -n "${STATIC_MANIFEST}" ]]
KEYED_ARTIFACT="$(dirname "${KEYED_MANIFEST}")"
STATIC_ARTIFACT="$(dirname "${STATIC_MANIFEST}")"

EXPECTED_SHARED_PATH="lib/native/native/installlib/${SHARED_LIBRARY}"
EXPECTED_STATIC_PATH="lib/native/libinstalllib-static.a"
grep -F "path = \"${EXPECTED_SHARED_PATH}\"" "${KEYED_MANIFEST}"
grep -F 'linkage = "shared"' "${KEYED_MANIFEST}"
grep -F "path = \"${EXPECTED_STATIC_PATH}\"" "${STATIC_MANIFEST}"
grep -F 'linkage = "static"' "${STATIC_MANIFEST}"
[[ -f "${KEYED_ARTIFACT}/${EXPECTED_SHARED_PATH}" ]]
[[ -f "${STATIC_ARTIFACT}/${EXPECTED_STATIC_PATH}" ]]
[[ -L ".moonstone/env/lib/native/${SHARED_LIBRARY}" ]]
[[ ! -e ".moonstone/env/lib/native/libinstalllib-static.a" ]]

rm -rf "${KEYED_ARTIFACT}" "${STATIC_ARTIFACT}" .moonstone/env
moon sync --locked

KEYED_MANIFEST="$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "install-lib-keyed"$' {} \; | head -1)"
STATIC_MANIFEST="$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "install-lib-static"$' {} \; | head -1)"
[[ -n "${KEYED_MANIFEST}" && -n "${STATIC_MANIFEST}" ]]
[[ -f "$(dirname "${KEYED_MANIFEST}")/${EXPECTED_SHARED_PATH}" ]]
[[ -f "$(dirname "${STATIC_MANIFEST}")/${EXPECTED_STATIC_PATH}" ]]
[[ -L ".moonstone/env/lib/native/${SHARED_LIBRARY}" ]]
[[ ! -e ".moonstone/env/lib/native/libinstalllib-static.a" ]]

echo "━━━ ✓ LuaRocks install.lib contract passed ━━━"
