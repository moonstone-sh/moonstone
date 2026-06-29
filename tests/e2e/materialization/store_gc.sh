#!/usr/bin/env bash
set -euo pipefail

# Test: Store GC
# - Installs inspect
# - Removes it
# - Runs GC and verifies it's gone from store

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
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

[runtime]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies.libs]
EOF

moon add inspect
moon sync

INSPECT_HASH=$(grep -A 10 'name = "inspect"' moonstone.lock | grep artifact_hash | head -n 1 | cut -d'"' -f2)

echo "━━━ remove inspect ━━━"
moon remove inspect

echo "━━━ run gc ━━━"
moon store gc

echo "━━━ verify artifact gone from store ━━━"
! moon store path "$INSPECT_HASH"
