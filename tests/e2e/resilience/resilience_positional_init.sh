#!/usr/bin/env bash
set -euo pipefail

# Test: Positional Path Init
# - Inits a project in a specific directory

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="/tmp/moonstone-test-positional"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

moon init my-project --lib --name "custom-name"

test -d "my-project"
test -f "my-project/moonstone.toml"
grep 'name = "custom-name"' my-project/moonstone.toml
