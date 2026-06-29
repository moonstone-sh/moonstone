#!/usr/bin/env bash
set -euo pipefail

# Test: Init Name Availability Check
# - Registers a project name
# - Verifies another project cannot use the same name

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="/tmp/moonstone-test-init-collision"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}/existing-project"
mkdir -p "${WORKDIR}/new-project"

cd "${WORKDIR}/existing-project"
moon init --name "pepe" --lib
moon link

cd "${WORKDIR}/new-project"
! moon init --name "pepe" --lib
