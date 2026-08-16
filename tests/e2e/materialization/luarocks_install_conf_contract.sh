#!/usr/bin/env bash
set -euo pipefail

# Contract: LuaRocks build.install.conf maps become non-projected Moonstone
# assets under assets/conf/, retain their keyed destination layout, and replay
# from the lock after the artifact and project environment are removed.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

RANDOM_PORT=$(((RANDOM % 1000) + 8600))
WORKDIR="$(mktemp -d /tmp/moonstone-rockspec-install-conf-contract.XXXXXX)"
MOCK_DIR="${WORKDIR}/mock-rocks"
SOURCE_DIR="${MOCK_DIR}/install-conf-0.1.0"
ARRAY_SOURCE_DIR="${MOCK_DIR}/install-conf-array-0.1.0"
TEST_APP="${WORKDIR}/app"

cleanup() {
    kill "${MOCK_PID:-}" 2>/dev/null || true
    wait "${MOCK_PID:-}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

mkdir -p "${SOURCE_DIR}/src" "${SOURCE_DIR}/config" "${ARRAY_SOURCE_DIR}/src" "${ARRAY_SOURCE_DIR}/config" "${TEST_APP}"

cat > "${SOURCE_DIR}/src/install_conf.lua" <<'EOF'
return "install.conf contract"
EOF
cat > "${SOURCE_DIR}/config/service.conf" <<'EOF'
listen = "127.0.0.1:8080"
EOF
cat > "${SOURCE_DIR}/config/default.conf" <<'EOF'
workers = 2
EOF
tar -czf "${MOCK_DIR}/install-conf-0.1.0.tar.gz" -C "${MOCK_DIR}" install-conf-0.1.0

cat > "${ARRAY_SOURCE_DIR}/src/install_conf_array.lua" <<'EOF'
return "install.conf array contract"
EOF
cat > "${ARRAY_SOURCE_DIR}/config/array.conf" <<'EOF'
mode = "array"
EOF
tar -czf "${MOCK_DIR}/install-conf-array-0.1.0.tar.gz" -C "${MOCK_DIR}" install-conf-array-0.1.0

cat > "${MOCK_DIR}/install-conf-0.1.0-1.rockspec" <<EOF
package = "install-conf"
version = "0.1.0-1"
source = { url = "http://127.0.0.1:${RANDOM_PORT}/install-conf-0.1.0.tar.gz" }
dependencies = { "lua >= 5.1" }
build = {
   type = "builtin",
   modules = { install_conf = "src/install_conf.lua" },
   install = {
      conf = {
         ["service/runtime.conf"] = "config/service.conf",
         ["default.conf"] = "config/default.conf",
      },
   },
}
EOF
cat > "${MOCK_DIR}/install-conf-array-0.1.0-1.rockspec" <<EOF
package = "install-conf-array"
version = "0.1.0-1"
source = { url = "http://127.0.0.1:${RANDOM_PORT}/install-conf-array-0.1.0.tar.gz" }
dependencies = { "lua >= 5.1" }
build = {
   type = "builtin",
   modules = { install_conf_array = "src/install_conf_array.lua" },
   install = {
      conf = { "config/array.conf" },
   },
}
EOF
cat > "${MOCK_DIR}/manifest-5.4.json" <<'EOF'
{"repository":{"install-conf":{"0.1.0-1":[{"arch":"rockspec"}]},"install-conf-array":{"0.1.0-1":[{"arch":"rockspec"}]}}}
EOF

(cd "${MOCK_DIR}" && python3 -m http.server "${RANDOM_PORT}" --bind 127.0.0.1) >"${WORKDIR}/server.log" 2>&1 &
MOCK_PID=$!

export MOONSTONE_LUAROCKS_URL="http://127.0.0.1:${RANDOM_PORT}"
for _ in {1..60}; do
    if curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null 2>&1; then
        break
    fi
    if ! kill -0 "${MOCK_PID}" 2>/dev/null; then
        echo "ERROR: mock LuaRocks server stopped before becoming ready" >&2
        cat "${WORKDIR}/server.log" >&2
        exit 1
    fi
    sleep 0.5
done
if ! curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null; then
    echo "ERROR: mock LuaRocks server did not become ready" >&2
    cat "${WORKDIR}/server.log" >&2
    exit 1
fi

cd "${TEST_APP}"

echo "━━━ resolve and materialize install.conf rock ━━━"
moon init . --name install-conf-contract --no-git --no-sync
moon interpreter set lua@5.4 --no-sync
moon add rocks:install-conf
moon add rocks:install-conf-array

STORE_DIR="${MOONSTONE_DATA}/store/v0"
ARTIFACT_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "install-conf"$' {} \; | head -1)
if [[ -z "${ARTIFACT_MANIFEST}" || ! -f "${ARTIFACT_MANIFEST}" ]]; then
    echo "ERROR: install.conf artifact manifest was not committed to the store" >&2
    exit 1
fi
ARTIFACT_DIR="$(dirname "${ARTIFACT_MANIFEST}")"
ARRAY_ARTIFACT_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "install-conf-array"$' {} \; | head -1)
if [[ -z "${ARRAY_ARTIFACT_MANIFEST}" || ! -f "${ARRAY_ARTIFACT_MANIFEST}" ]]; then
    echo "ERROR: install.conf array artifact manifest was not committed to the store" >&2
    exit 1
fi
ARRAY_ARTIFACT_DIR="$(dirname "${ARRAY_ARTIFACT_MANIFEST}")"

echo "━━━ assert keyed config asset layout and non-projection ━━━"
grep -Fq 'asset = [{ name = "conf/default.conf", path = "assets/conf/default.conf" }, { name = "conf/service/runtime.conf", path = "assets/conf/service/runtime.conf" }]' "${ARTIFACT_MANIFEST}"
grep -Fq 'workers = 2' "${ARTIFACT_DIR}/files/assets/conf/default.conf"
grep -Fq '127.0.0.1:8080' "${ARTIFACT_DIR}/files/assets/conf/service/runtime.conf"
grep -Fq 'asset = [{ name = "conf/array.conf", path = "assets/conf/array.conf" }]' "${ARRAY_ARTIFACT_MANIFEST}"
grep -Fq 'mode = "array"' "${ARRAY_ARTIFACT_DIR}/files/assets/conf/array.conf"
moon exec -- lua -e 'print(require("install_conf"))' | grep -q 'install.conf contract'
moon exec -- lua -e 'print(require("install_conf_array"))' | grep -q 'install.conf array contract'
if moon exec -- lua -e 'assert(package.searchpath("runtime", package.path) == nil)' >/dev/null 2>&1; then
    :
else
    echo "ERROR: install.conf asset unexpectedly became a Lua runtime module" >&2
    exit 1
fi

echo "━━━ purge and replay the locked config asset closure ━━━"
rm -rf "${ARTIFACT_DIR}" "${ARRAY_ARTIFACT_DIR}" .moonstone/env
moon sync --locked

RESTORED_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "install-conf"$' {} \; | head -1)
if [[ -z "${RESTORED_MANIFEST}" || ! -f "${RESTORED_MANIFEST}" ]]; then
    echo "ERROR: locked replay did not restore the install.conf artifact" >&2
    exit 1
fi
RESTORED_DIR="$(dirname "${RESTORED_MANIFEST}")"
RESTORED_ARRAY_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "install-conf-array"$' {} \; | head -1)
if [[ -z "${RESTORED_ARRAY_MANIFEST}" || ! -f "${RESTORED_ARRAY_MANIFEST}" ]]; then
    echo "ERROR: locked replay did not restore the install.conf array artifact" >&2
    exit 1
fi
RESTORED_ARRAY_DIR="$(dirname "${RESTORED_ARRAY_MANIFEST}")"
grep -Fq 'workers = 2' "${RESTORED_DIR}/files/assets/conf/default.conf"
grep -Fq '127.0.0.1:8080' "${RESTORED_DIR}/files/assets/conf/service/runtime.conf"
grep -Fq 'mode = "array"' "${RESTORED_ARRAY_DIR}/files/assets/conf/array.conf"
moon exec -- lua -e 'print(require("install_conf"))' | grep -q 'install.conf contract'
moon exec -- lua -e 'print(require("install_conf_array"))' | grep -q 'install.conf array contract'

echo "━━━ ✓ LuaRocks install.conf asset and replay contract passed ━━━"
