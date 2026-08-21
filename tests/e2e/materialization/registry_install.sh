#!/usr/bin/env bash
set -euo pipefail

# Test: Registry install
# - Adds inspect from registry
# - Installs and verifies it works via moon exec

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

cd "${SANDBOX_DIR}/my-app"

# Reset my-app
rm -rf .moonstone
rm -f moonstone.lock
cat > moonstone.toml <<EOF
[package]
name = "my-app"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies.runtime]

[[registries]]
name = "synthetic"
resolver = "moonstone"
path = "${SANDBOX_DIR}/registry"
EOF

moon interpreter set lua@5.4
moon add synthetic:inspect
moon sync

echo "━━━ run registry inspect test ━━━"
cat > src/inspect_test.lua << 'EOF'
local inspect = require("inspect")
print(inspect({test = "registry works"}))
EOF
moon exec -- lua src/inspect_test.lua | grep "registry works"

echo "━━━ moon exec test: check inspect available ━━━"
moon exec -- lua -e 'local inspect = require("inspect"); print("Type: " .. type(inspect))' | grep -E "Type: (function|table)"
