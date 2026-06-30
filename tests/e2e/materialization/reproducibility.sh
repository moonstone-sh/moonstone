#!/usr/bin/env bash
set -euo pipefail

# Test: Reproducibility (--locked)
# - Verifies success on valid lockfile
# - Verifies failure on missing entry or hash mismatch

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

[dependencies.runtime]
synthetic-make-module = "*"
EOF

echo "━━━ initial install ━━━"
moon sync

echo "━━━ locked install (success) ━━━"
moon sync --locked

echo "━━━ locked install (missing entry error) ━━━"
echo '[dependencies.runtime]' >> moonstone.toml
echo 'luassert = "*"' >> moonstone.toml
! moon sync --locked

echo "━━━ sync lockfile ━━━"
moon sync

echo "━━━ locked install (hash mismatch error) ━━━"
sed -i.bak 's/artifact_hash = "b3:.*"/artifact_hash = "b3:corrupted"/' moonstone.lock
! moon sync --locked
