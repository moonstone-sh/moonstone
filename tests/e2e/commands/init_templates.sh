#!/usr/bin/env bash
set -euo pipefail

# Test: Init Templates
# - Verifies all templates generate expected files

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

TEMPLATES=("script" "lib" "nvim" "love" "lua-zig" "c-bin" "zig-bin" "rust-bin" "bin")

for T in "${TEMPLATES[@]}"; do
    echo "━━━ testing template: $T ━━━"
    WORKDIR="/tmp/moon-test-template-$T"
    rm -rf "${WORKDIR}"
    mkdir -p "${WORKDIR}"
    
    moon init "${WORKDIR}" --template "$T" --name "tmp-$T-$(date +%s)" --no-sync
    
    case $T in
        script)
            [[ -f "${WORKDIR}/src/main.lua" ]]
            [[ -f "${WORKDIR}/.luarc.json" ]]
            grep -Fq '.moonstone/env/libexec' "${WORKDIR}/.luarc.json"
            ;;
        lib)
            [[ -f "${WORKDIR}/src/my-lib.lua" ]]
            [[ -f "${WORKDIR}/.luarc.json" ]]
            ;;
        nvim)
            MODULE_NAME="tmp_nvim_$(date +%s)"
            MODULE_NAME="$(find "${WORKDIR}/lua" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)"
            [[ -f "${WORKDIR}/lua/${MODULE_NAME}/init.lua" ]]
            [[ -f "${WORKDIR}/lua/${MODULE_NAME}/config.lua" ]]
            [[ -f "${WORKDIR}/plugin/${MODULE_NAME}.lua" ]]
            [[ -f "${WORKDIR}/doc/${MODULE_NAME}.txt" ]]
            [[ -f "${WORKDIR}/tests/minimal_init.lua" ]]
            [[ -f "${WORKDIR}/partiture.lua" ]]
            [[ -f "${WORKDIR}/README.md" ]]
            [[ -f "${WORKDIR}/.luarc.json" ]]
            grep "vim" "${WORKDIR}/.luarc.json"
            grep -q 'name = "luajit"' "${WORKDIR}/moonstone.toml"
            grep -q 'version = "2.1"' "${WORKDIR}/moonstone.toml"
            grep -q 'abi = "5.1"' "${WORKDIR}/moonstone.toml"
            grep -q 'moonstone/ballad' "${WORKDIR}/moonstone.toml"
            grep -q 'module = "'"${MODULE_NAME}"'"' "${WORKDIR}/partiture.lua"
            grep -q 'local nvim_version = os.getenv("NVIM_VERSION") or "0.12.2"' "${WORKDIR}/partiture.lua"
            grep -q 'runtime = nvim_runtime' "${WORKDIR}/partiture.lua"
            ;;
        love)
            [[ -f "${WORKDIR}/main.lua" ]]
            [[ -f "${WORKDIR}/conf.lua" ]]
            [[ -f "${WORKDIR}/.luarc.json" ]]
            ;;
        c-bin)
            [[ -f "${WORKDIR}/src/main.c" ]]
            [[ -f "${WORKDIR}/Makefile" ]]
            ;;
        zig-bin)
            [[ -f "${WORKDIR}/src/main.zig" ]]
            [[ -f "${WORKDIR}/build.zig" ]]
            ;;
        lua-zig)
            [[ -f "${WORKDIR}/src/main.lua" ]]
            [[ -f "${WORKDIR}/src/app.lua" ]]
            [[ -f "${WORKDIR}/zig/bridge.zig" ]]
            [[ -f "${WORKDIR}/build.zig" ]]
            [[ -f "${WORKDIR}/.luarc.json" ]]
            [[ -f "${WORKDIR}/README.md" ]]
            grep "require(\"tmp_lua_zig_" "${WORKDIR}/src/app.lua"
            grep "luaopen_tmp_lua_zig" "${WORKDIR}/zig/bridge.zig"
            ;;
        rust-bin)
            [[ -f "${WORKDIR}/src/main.rs" ]]
            [[ -f "${WORKDIR}/Cargo.toml" ]]
            ;;
        bin)
            [[ -f "${WORKDIR}/src/main.c" ]]
            ;;
    esac
    
    rm -rf "${WORKDIR}"
done

echo "━━━ testing LuaLS runtime-library refresh ━━━"
LSP_WORKDIR="$(mktemp -d /tmp/moon-test-luarc-runtime.XXXXXX)"
trap 'rm -rf "${LSP_WORKDIR}"' EXIT
moon init "${LSP_WORKDIR}" --name "tmp-luarc-runtime-$(date +%s)" --interpreter lua@5.4 --no-sync --no-git
grep -Fq '.moonstone/env/share/lua/5.4' "${LSP_WORKDIR}/.luarc.json"
moon -C "${LSP_WORKDIR}" interpreter set luajit@2.1
grep -Fq '.moonstone/env/share/lua/5.1' "${LSP_WORKDIR}/.luarc.json"
! grep -Fq '.moonstone/env/share/lua/5.4' "${LSP_WORKDIR}/.luarc.json"
grep -Fq '.moonstone/env/libexec' "${LSP_WORKDIR}/.luarc.json"
rm -rf "${LSP_WORKDIR}"
trap - EXIT

echo "━━━ testing empty project ━━━"
EMPTY_WORKDIR="/tmp/moon-test-template-empty"
rm -rf "${EMPTY_WORKDIR}"
mkdir -p "${EMPTY_WORKDIR}"
moon init "${EMPTY_WORKDIR}" --empty --name "tmp-empty-$(date +%s)" --no-sync --no-git
[[ -f "${EMPTY_WORKDIR}/moonstone.toml" ]]
[[ ! -e "${EMPTY_WORKDIR}/src" ]]
[[ ! -e "${EMPTY_WORKDIR}/.luarc.json" ]]
[[ ! -e "${EMPTY_WORKDIR}/README.md" ]]
rm -rf "${EMPTY_WORKDIR}"

echo "━━━ testing init without optional git ━━━"
NO_GIT_WORKDIR="$(mktemp -d /tmp/moon-test-init-no-git.XXXXXX)"
NO_GIT_PATH="${NO_GIT_WORKDIR}/empty-path"
mkdir -p "${NO_GIT_PATH}"
if ! PATH="${NO_GIT_PATH}" "${PROJECT_ROOT}/zig-out/bin/moon" init "${NO_GIT_WORKDIR}/project" --name no-git --no-sync >"${NO_GIT_WORKDIR}/output" 2>&1; then
    cat "${NO_GIT_WORKDIR}/output" >&2
    echo "moon init must succeed when optional git is unavailable" >&2
    exit 1
fi
grep -Fq "skipped Git initialization" "${NO_GIT_WORKDIR}/output"
[[ -f "${NO_GIT_WORKDIR}/project/moonstone.toml" ]]
rm -rf "${NO_GIT_WORKDIR}"

echo "━━━ ✓ Init templates test passed ━━━"
