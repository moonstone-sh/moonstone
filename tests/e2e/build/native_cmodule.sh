#!/usr/bin/env bash
set -euo pipefail

# Test: Native C module materialization
# - Adds synthetic-cmodule
# - Builds and verifies it works via moon exec

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "$(dirname "$0")/../../scripts/install_synthetic.sh"
fi

cd "${SANDBOX_DIR}/my-app"

# Reset my-app
rm -rf .moonstone
rm -f moonstone.lock
cat > moonstone.toml << 'EOF'
[package]
name = "my-app"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[registries]
synthetic = { path = "${SANDBOX_DIR}/registry", priority = 10 }

[dependencies.runtime]
EOF

moon interpreter set lua@5.4
moon add synthetic-cmodule
moon sync

echo "━━━ check cmodule symlink ━━━"
test -L .moonstone/env/lib/lua/5.4/synthetic_cmodule.so

echo "━━━ run cmodule test ━━━"
moon exec -- lua -e 'local m = require("synthetic_cmodule"); print(m.hello())' | grep "hello from synthetic cmodule"

echo "━━━ ✓ native C module materialization passed ━━━"
