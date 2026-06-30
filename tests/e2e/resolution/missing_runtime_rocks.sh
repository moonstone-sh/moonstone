#!/usr/bin/env bash
set -uo pipefail

# Test: Missing Runtime for Rocks Parsing
# - Attempts to add a rock without an active Lua runtime
# - Verifies a clear error message is shown

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="/tmp/moonstone-test-missing-runtime-rocks"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

echo "━━━ Setup Project (No Runtime) ━━━"
moon init . --name "missing-runtime-test" --no-git

echo "━━━ Attempt to add rock ━━━"
# This should fail early because resolving 'lua' for the materializer fails
set +o pipefail
moon add rocks:inspect 2>&1 | tee output.log
set -o pipefail

grep "Error: Moonstone requires an active Lua runtime for this command" output.log
grep "Please run \`moon interpreter set lua@5.4\` or \`moon interpreter install\` first" output.log

echo "━━━ ✓ Missing runtime for rocks test passed ━━━"
