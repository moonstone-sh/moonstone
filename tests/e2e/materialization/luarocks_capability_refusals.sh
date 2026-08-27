#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

RANDOM_PORT=$(( ( RANDOM % 1000 ) + 8300 ))
MOCK_DIR="/tmp/moonstone-rockspec-capability-refusals"
TEST_ROOT="${SANDBOX_DIR}/rockspec-capability-refusals"
BASE_SPEC="${MOCK_DIR}/base.rockspec"

rm -rf "${MOCK_DIR}" "${TEST_ROOT}"
mkdir -p "${MOCK_DIR}" "${TEST_ROOT}"
cp "${PROJECT_ROOT}/fixtures/sandbox-reference/mock-luarocks/fakebin-1.0.tar.gz" "${MOCK_DIR}/fakebin-1.0.tar.gz"
cp "${PROJECT_ROOT}/fixtures/sandbox-reference/mock-luarocks/fakebin-1.0-1.rockspec" "${BASE_SPEC}"
perl -pi -e "s/localhost:8641/localhost:${RANDOM_PORT}/g" "${BASE_SPEC}"

declare -a cases=(
    'hooks:UnsupportedLuaRocksHooks'
    'patch_create_delete:UnsupportedPatchCreateDelete'
    'install_bin_name:InvalidLuaRocksInstallBinName'
    'install_bin_path:InvalidLuaRocksInstallBinPath'
    'install_lib_filename:UnsupportedLuaRocksInstallLibFilename'
    'source_md5:LuaRocksSourceMd5Mismatch'
    'supported_platforms:UnsupportedLuaRocksPlatform'
    'command_missing_build:MissingLuaRocksBuildCommand'
    'command_missing_install:MissingLuaRocksInstallCommand'
    # Custom backends are rejected with a deliberately actionable diagnostic,
    # rather than exposing the implementation-only Zig error name.
    'build_type:uses custom build backend `custom`'
)

for case_entry in "${cases[@]}"; do
    case_name="${case_entry%%:*}"
    package_name="capability-${case_name}"
    spec_path="${MOCK_DIR}/${package_name}-1.0-1.rockspec"
    cp "${BASE_SPEC}" "${spec_path}"
    perl -0pi -e "s/package = \"fakebin\"/package = \"${package_name}\"/" "${spec_path}"

    case "${case_name}" in
        hooks)
            cat >> "${spec_path}" <<'EOF'

hooks = {
   post_install = "echo host mutation",
}
EOF
            ;;
        patch_create_delete)
            cat >> "${spec_path}" <<'EOF'

build.patches = {
   ["create.patch"] = [[
--- /dev/null
+++ b/created.lua
@@ -0,0 +1 @@
+return 1
]],
}
EOF
            ;;
        install_bin_name)
            cat >> "${spec_path}" <<'EOF'

build.install.bin = { ["nested/bin"] = "fake.lua" }
EOF
            ;;
        install_bin_path)
            cat >> "${spec_path}" <<'EOF'

build.install.bin = { fakebin = "../fake.lua" }
EOF
            ;;
        install_lib_filename)
            perl -0pi -e 's/install = \{/install = {\n      lib = { fake = "fake.lua" },/' "${spec_path}"
            ;;
        source_md5)
            perl -0pi -e 's/source = \{/source = {\n   md5 = "00000000000000000000000000000000",/' "${spec_path}"
            ;;
        supported_platforms)
            cat >> "${spec_path}" <<'EOF'

supported_platforms = { "win32" }
EOF
            ;;
        command_missing_build)
            perl -0pi -e 's/type = "builtin",/type = "command",\n   install_command = "true",/' "${spec_path}"
            ;;
        command_missing_install)
            perl -0pi -e 's/type = "builtin",/type = "command",\n   build_command = "true",/' "${spec_path}"
            ;;
        build_type)
            perl -0pi -e 's/type = "builtin"/type = "custom"/' "${spec_path}"
            ;;
    esac
done

{
    printf '{"repository":{'
    for index in "${!cases[@]}"; do
        case_name="${cases[${index}]%%:*}"
        package_name="capability-${case_name}"
        if [[ "${index}" -gt 0 ]]; then
            printf ','
        fi
        printf '"%s":{"1.0-1":[{"arch":"rockspec"}]}' "${package_name}"
    done
    printf '}}\n'
} > "${MOCK_DIR}/manifest-5.4.json"

python3 -m http.server "${RANDOM_PORT}" --directory "${MOCK_DIR}" >/tmp/moonstone-rockspec-capability-refusals-server.log 2>&1 &
MOCK_PID=$!
trap 'kill "${MOCK_PID}" 2>/dev/null || true' EXIT

export MOONSTONE_LUAROCKS_URL="http://localhost:${RANDOM_PORT}"
for _ in {1..60}; do
    if curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null

assert_error() {
    local output="$1"
    local expected_error="$2"
    if ! printf '%s' "${output}" | grep -F "${expected_error}" >/dev/null; then
        echo "ERROR: expected ${expected_error}, received:" >&2
        printf '%s\n' "${output}" >&2
        exit 1
    fi
}

for case_entry in "${cases[@]}"; do
    case_name="${case_entry%%:*}"
    expected_error="${case_entry#*:}"
    package_name="capability-${case_name}"
    test_app="${TEST_ROOT}/${case_name}"
    mkdir -p "${test_app}"

    pushd "${test_app}" >/dev/null
    moon init . --name "${package_name}" --no-git
    moon interpreter set lua@5.4
    if output="$(moon add "rocks:${package_name}" 2>&1)"; then
        echo "ERROR: Moonstone materialized unsupported LuaRocks capability ${case_name}" >&2
        exit 1
    fi
    assert_error "${output}" "${expected_error}"

    if [[ "${case_name}" == build_type ]]; then
        printf '\n[[dependencies]]\nname = "rocks:%s"\nrole = "runtime"\n' "${package_name}" >> moonstone.toml
        if output="$(moon sync 2>&1)"; then
            echo "ERROR: moon sync accepted explicit unsupported LuaRocks build backend" >&2
            exit 1
        fi
        # Explicit sync follows the same deterministic source-preparation
        # path and must retain the actionable backend diagnostic.
        assert_error "${output}" "${expected_error}"
    fi
    popd >/dev/null
done

echo "━━━ ✓ LuaRocks materialization capability refusals passed ━━━"
