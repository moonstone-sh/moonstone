#!/usr/bin/env bash
set -euo pipefail

# Test: CMake generic materialization
# - Inits cmake test project
# - Adds synthetic-cmake-module
# - Verifies it works via moon exec

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "$(dirname "$0")/../../scripts/install_synthetic.sh"
fi

if ! command -v cmake &> /dev/null; then
    echo "  ! Skipping 08-cmake-module.sh (cmake not found)"
    exit 0
fi

CMAKE_WORKDIR="/tmp/moonstone-test-cmake"
rm -rf "${CMAKE_WORKDIR}"
mkdir -p "${CMAKE_WORKDIR}"

cd "${CMAKE_WORKDIR}"
moon init --name cmake-test --kind script
cat >> moonstone.toml <<EOF

[[registries]]
name = "synthetic"
resolver = "moonstone"
path = "${SANDBOX_DIR}/registry"
priority = 10
EOF
moon interpreter set lua@5.4
moon add synthetic:synthetic-cmake-module
moon sync

echo "━━━ check cmake module symlink ━━━"
find .moonstone/env/lib/lua -type l -name 'synthetic_cmake_module.*' | grep -q .

echo "━━━ run cmake module test ━━━"
moon exec -- lua -e 'local m = require("synthetic_cmake_module"); assert(m.hello() == "hello from synthetic cmake module"); print("Functional test passed")' | grep "Functional test passed"
