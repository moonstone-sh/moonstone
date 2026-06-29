#!/usr/bin/env bash
set -euo pipefail

# Test: Symlink Collision & Overwrite
# - Manually creates a file where a shim should go
# - Verifies moon sync overwrites it

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="/tmp/moonstone-test-collision"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

moon init --name collision-test --kind script
moon use lua@5.4

mkdir -p .moonstone/env/bin
rm -f .moonstone/env/bin/lua
echo "EXISTING" > .moonstone/env/bin/lua

moon sync

test -x .moonstone/env/bin/lua
