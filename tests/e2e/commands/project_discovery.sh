#!/usr/bin/env bash
set -euo pipefail

source "${PROJECT_ROOT}/tests/scripts/lib/assert.sh"

WORKDIR="/tmp/moonstone-contract-project-discovery"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}/parent/child/grandchild"
cd "${WORKDIR}/parent"

moon init . --name discovery-test --no-git
moon use lua@5.4 --no-sync

cd child/grandchild
list_output=$(moon list)
assert_contains "${list_output}" "Project: discovery-test" "list discovers parent project"

run_output=$(moon run missing 2>&1 || true)
assert_contains "${run_output}" "script 'missing' not found" "run discovers parent project"


moon add inspect@3.1.3 --no-sync
assert_file_contains "${WORKDIR}/parent/moonstone.toml" '"inspect" = "^3.1.3"'

tmp_out=$(mktemp)
cd /tmp
if moon add inspect >"${tmp_out}" 2>&1; then
  echo "✗ moon add outside a project should fail"
  cat "${tmp_out}"
  exit 1
fi
outside_output=$(cat "${tmp_out}")
assert_contains "${outside_output}" "not inside a Moonstone project" "outside project error"
