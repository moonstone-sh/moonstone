#!/usr/bin/env bash
set -uo pipefail

# Test: moon run Semantics
# - Verifies PATH resolution (hitting .moonstone/env/bin/lua)
# - Verifies opaque host-shell command interpretation
# - Verifies shell-owned sequential chaining
# - Verifies exit code propagation
# - Verifies missing script error reporting

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"
export PATH="${MOON_BIN%/*}:${PATH}"

WORKDIR="/tmp/moonstone-test-run-semantics"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

echo "━━━ Setup Project ━━━"
moon init . --name "semantics-test" --no-git
moon interpreter set lua@5.4

# Create a fake project-local Lua that tracks arguments
mkdir -p .moonstone/env/bin
rm -f .moonstone/env/bin/lua
cat > .moonstone/env/bin/lua <<'SH'
#!/usr/bin/env sh
printf 'MOONSTONE_LUA'
for arg in "$@"; do
  printf '[%s]' "$arg"
done
printf '\n'
SH
chmod +x .moonstone/env/bin/lua

echo "━━━ Test 1: PATH resolution (lua hits project-local) ━━━"
# Add declarative scripts to moonstone.toml.
cat >> moonstone.toml << 'EOF'
[scripts]
quoted = 'lua -e "print(\"hello world\")"'
compound = 'echo before && lua ./src/main.lua && echo after'
bad = "exit 42"
EOF

moon run dev | grep "MOONSTONE_LUA\[./src/main.lua\]"

echo "━━━ Test 2: Opaque command preserves shell quoting ━━━"
moon run quoted | grep "MOONSTONE_LUA\[-e\]\[print(\"hello world\")\]"

echo "━━━ Test 3: Shell chaining works ━━━"
# Use tee to see output while capturing
moon run compound 2>&1 | tee compound_out
grep "before" compound_out
grep "MOONSTONE_LUA\[./src/main.lua\]" compound_out
grep "after" compound_out

echo "━━━ Test 4: Failed script propagates exit code ━━━"
set +e
moon run bad
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 42 ]]; then
    echo "  ✗ Expected exit code 42, got $EXIT_CODE"
    exit 1
fi
echo "  ✓ Propagated exit code 42"

echo "━━━ Test 5: Missing script errors ━━━"
set +o pipefail
moon run missing 2>&1 | grep "Error: script 'missing' not found"
set -o pipefail

echo "━━━ ✓ moon run semantics passed ━━━"
