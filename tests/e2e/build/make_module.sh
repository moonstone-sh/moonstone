#!/usr/bin/env bash
set -euo pipefail

# Test: Generic command materialization (make)
# - Adds synthetic-make-module
# - Builds and verifies it works via moon exec

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "$(dirname "$0")/../../scripts/install_synthetic.sh"
fi

cd "${SANDBOX_DIR}/my-app"

# Reset my-app
rm -rf .moonstone
rm -f moonstone.lock
cat > moonstone.toml << EOF
[package]
name = "my-app"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[[registries]]
name = "synthetic"
resolver = "moonstone"
path = "${SANDBOX_DIR}/registry"
priority = 10

[dependencies.runtime]
EOF

moon interpreter set lua@5.4
moon add synthetic:synthetic-make-module
moon sync

# Exercise the queued progress worker during a locked replay. This is distinct
# from the normal CI/non-interactive output path and protects cancellation and
# scheduler context handling from regressing behind a direct-output-only test.
moon sync --progress fancy </dev/null

echo "━━━ check make module symlink ━━━"
find .moonstone/env/lib/lua -type l -name 'synthetic_make_module.*' | grep -q .

echo "━━━ run make module test ━━━"
moon exec -- lua -e 'local m = require("synthetic_make_module"); print(m.hello())' | grep "hello from synthetic make module"
