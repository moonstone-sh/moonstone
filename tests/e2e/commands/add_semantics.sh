#!/usr/bin/env bash
set -euo pipefail

source "${PROJECT_ROOT}/tests/scripts/lib/assert.sh"

WORKDIR="/tmp/moonstone-contract-add"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

moon init . --name add-contract --no-git
moon use lua@5.4 --no-sync

moon add inspect@3.1.2 --no-sync
assert_file_contains moonstone.toml '"inspect" = "^3.1.2"'
assert_file_contains moonstone.lock 'name = "inspect"'
assert_file_contains moonstone.lock 'version = "3.1.2"'

moon add inspect@3.1.3 --save-exact --no-sync
assert_file_contains moonstone.toml '"inspect" = "3.1.3"'

moon add luassert@1.9.0 --save-tilde --dev --no-sync
assert_file_contains moonstone.toml '[dependencies.dev_libs]'
assert_file_contains moonstone.toml '"luassert" = "~1.9.0"'

before=$(cat moonstone.toml)
moon add synthetic-make-module --dry-run --no-sync
if [[ "$(cat moonstone.toml)" != "${before}" ]]; then
  echo "✗ dry-run changed moonstone.toml"
  exit 1
fi

if moon add definitely-not-a-real-package --no-sync >/tmp/moonstone-contract-add-missing.out 2>&1; then
  echo "✗ missing package should fail"
  exit 1
fi
assert_contains "$(cat /tmp/moonstone-contract-add-missing.out)" "package not found" "missing package error"
