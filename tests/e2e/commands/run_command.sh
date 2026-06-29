#!/usr/bin/env bash
set -euo pipefail

# Test: moon run command
# - Defines scripts in moonstone.toml
# - Verifies execution of scripts via moon run

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="/tmp/moonstone-test-run"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

moon init . --name "run-test"
moon use lua@5.4

# Add scripts to moonstone.toml
cat >> moonstone.toml << 'EOF'
hello = "echo 'Hello from Moonstone script'"
test_lua = "lua -e 'print(\"Lua execution works\")'"
EOF

echo "━━━ run simple script ━━━"
moon run hello | grep "Hello from Moonstone script"

echo "━━━ run lua script ━━━"
moon run test_lua | grep "Lua execution works"

echo "━━━ ✓ moon run test passed ━━━"
