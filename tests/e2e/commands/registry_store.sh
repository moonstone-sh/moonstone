#!/usr/bin/env bash
set -euo pipefail

source "${PROJECT_ROOT}/tests/scripts/lib/assert.sh"

WORKDIR="/tmp/moonstone-contract-registry-store"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}/project/subdir"
cd "${WORKDIR}/project"

moon init . --name registry-store-contract --no-git
moon interpreter set lua@5.4 --no-sync

cd subdir
moon registry add local-synthetic "${SANDBOX_DIR}/registry" --default
assert_file_contains "${WORKDIR}/project/moonstone.toml" '[registries."local-synthetic"]'
assert_file_contains "${WORKDIR}/project/moonstone.toml" "${SANDBOX_DIR}/registry"

registry_output=$(moon registry list)
assert_contains "${registry_output}" "local-synthetic" "registry list from subdir"

registry_json=$(moon registry list --json)
assert_json_valid "${registry_json}"
assert_ndjson_terminator "${registry_json}"
assert_last_json_field "${registry_json}" "kind" "RESULT"

moon registry remove local-synthetic
assert_file_not_contains "${WORKDIR}/project/moonstone.toml" 'local-synthetic'

moon add inspect@3.1.3

store_output=$(moon store list)
assert_contains "${store_output}" "inspect" "store list includes installed package"

store_json=$(moon store list --json)
assert_json_valid "${store_json}"
assert_ndjson_terminator "${store_json}"
assert_last_json_field "${store_json}" "kind" "RESULT"

store_path=$(moon store path inspect@3.1.3)
if [[ ! -d "${store_path}" ]]; then
  echo "✗ store path does not exist: ${store_path}"
  exit 1
fi

links_output=$(moon store list --links)
assert_contains "${links_output}" "Name" "store links header"
