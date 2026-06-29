#!/usr/bin/env bash
set -euo pipefail

# Test: Offline Mode Enforcement
# - Verifies moon add fails when --offline and no cache

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="/tmp/moonstone-test-offline"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

moon init --name offline-test --kind script

! moon add definitely-not-cached-offline-probe --offline
