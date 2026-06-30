#!/usr/bin/env bash
set -euo pipefail

# Test: Registered links are suggested by completion and consumed with moon add.

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

cd "${SANDBOX_DIR}/my-lib"
moon link --force

moon completions --complete 'moon add link:' | grep 'link:my-lib'

cd "${SANDBOX_DIR}/my-app"
rm -rf .moonstone
rm -f moonstone.lock
cat > moonstone.toml << 'EOF_TOML'
[package]
name = "my-app"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies.dependency]
EOF_TOML

moon interpreter set lua@5.4
moon add link:my-lib --no-sync
moon sync

moon exec -- lua src/main.lua | grep "Hello, synthetic!"
test -L .moonstone/env/share/lua/5.4/my_lib/init.lua
