#!/usr/bin/env bash
set -euo pipefail

# Test: Global Use and Shims
# - Sets a global default runtime
# - Verifies it works outside project
# - Verifies shims work

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

# Move to a clean directory that is NOT a project to test global fallback
CLEAN_WORKDIR="/tmp/moon-test-global-clean"
rm -rf "${CLEAN_WORKDIR}"
mkdir -p "${CLEAN_WORKDIR}"
cd "${CLEAN_WORKDIR}"

# 1. Set global runtime
echo "━━━ set global runtime 5.4 ━━━"
moon use --global lua@5.4.7

# 2. Verify config.toml
echo "━━━ verify config.toml ━━━"
grep "default_runtime = \"lua-5.4.7\"" "${MOONSTONE_HOME}/config/config.toml"

# 3. Setup shims
echo "━━━ moon setup ━━━"
moon setup --force

# 4. Verify shims work outside project
echo "━━━ verify shim outside project ━━━"
# We need to put shims in PATH for this test to be realistic
export PATH="${MOONSTONE_HOME}/data/v0/shims:${PATH}"

SHIM_VERSION=$(lua -v 2>&1)
echo "Got version: ${SHIM_VERSION}"
echo "${SHIM_VERSION}" | grep "Lua 5.4"

# 5. Verify shim respects project-local environment
echo "━━━ verify shim inside project ━━━"
WORKDIR="/tmp/moon-test-global-shim"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

moon init --name "p54" --lib --runtime lua@5.4.7
moon sync

SHIM_VERSION_LOCAL=$(lua -v 2>&1)
echo "Got local version: ${SHIM_VERSION_LOCAL}"
echo "${SHIM_VERSION_LOCAL}" | grep "Lua 5.4"

echo "━━━ ✓ Global use and shims test passed ━━━"
rm -rf "${WORKDIR}"
