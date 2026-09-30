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
moon interpreter set lua@5.4

# Add scripts under [scripts]: `moon init` no longer leaves it as the
# manifest's last table (a [[registries]] entry follows it).
cat > /tmp/moonstone-test-run-scripts.toml << 'EOF'
hello = "echo 'Hello from Moonstone script'"
test_lua = "lua -e 'print(\"Lua execution works\")'"
EOF
awk 'FNR==NR { extra = extra $0 "\n"; next } { print } /^\[scripts\]$/ { printf "%s", extra }' \
  /tmp/moonstone-test-run-scripts.toml moonstone.toml > moonstone.toml.new && mv moonstone.toml.new moonstone.toml

echo "━━━ run simple script ━━━"
moon run hello | grep "Hello from Moonstone script"

echo "━━━ run lua script ━━━"
moon run test_lua | grep "Lua execution works"

echo "━━━ ✓ moon run test passed ━━━"
