#!/usr/bin/env bash
set -euo pipefail

# Test: Local live link
# - Registers my-lib
# - Links my-lib into my-app
# - Verifies my-app can call a method from my-lib via moon exec

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

echo "━━━ register my-lib ━━━"
# Copy my-lib to a temp dir to avoid stale link registrations from other tests
LINK_SRC="$(mktemp -d /tmp/moonstone-local-link-src.XXXXXX)"
cp -R "${SANDBOX_DIR}/my-lib"/* "${LINK_SRC}/"
cd "${LINK_SRC}"
moon link

echo "━━━ consume my-lib in my-app ━━━"
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

[dependencies.runtime]
EOF

moon add link:my-lib --no-sync
moon interpreter set lua@5.4
moon sync

echo "━━━ verify project linking and method call ━━━"
# The current my-app/src/main.lua already calls my_lib.greet("synthetic")
moon exec -- lua src/main.lua | grep "Hello, synthetic!"

echo "━━━ test moon exec with inline code ━━━"
moon exec -- lua -e 'local m = require("my_lib"); print("Result: " .. m.greet("modular-tests"))' | grep "Result: Hello, modular-tests!"

echo "━━━ check env has live symlink ━━━"
test -L .moonstone/env/share/lua/5.4/my_lib/init.lua || test -d .moonstone/env/share/lua/5.4/my_lib
