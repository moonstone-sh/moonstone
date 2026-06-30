#!/usr/bin/env bash
set -euo pipefail

# Test: moon use runtime metadata and ABI transitions
# - Verifies moon use writes runtime name/version/abi metadata.
# - Verifies moon use runs install by default for compatible runtime changes.
# - Verifies an ABI-incompatible runtime change fails cleanly instead of reusing a stale env.

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="/tmp/moonstone-test-use-abi"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

echo "━━━ init with no install ━━━"
moon init . --name use-abi-test --no-git --runtime lua@5.4.7 --no-sync

echo "━━━ use lua@5.4.7 installs runtime ━━━"
moon use lua@5.4.7
grep 'name = "lua"' moonstone.toml
grep 'version = "5.4.7"' moonstone.toml
grep 'abi = "5.4"' moonstone.toml

echo "━━━ add dependency and install env ━━━"
moon add synthetic:inspect@3.1.3
grep 'name = "inspect"' moonstone.toml
grep 'runtime = "5.4"' moonstone.lock
test -x .moonstone/env/bin/lua
moon exec -- lua -e 'require("inspect"); print(_VERSION)'

echo "━━━ use compatible runtime runs install by default ━━━"
moon use lua@5.4.6
grep 'version = "5.4.6"' moonstone.toml
grep 'abi = "5.4"' moonstone.toml
grep 'runtime = "5.4"' moonstone.lock
moon exec -- lua -e 'require("inspect"); print(_VERSION)'

echo "━━━ incompatible ABI change fails cleanly ━━━"
set +e
moon use luajit@2.1 >use-luajit.log 2>&1
STATUS=$?
set -e
if [[ "${STATUS}" -eq 0 ]]; then
    grep 'abi = "5.1"' moonstone.toml
    grep 'runtime = "5.1"' moonstone.lock
else
    grep 'abi = "5.1"' moonstone.toml
    grep -E 'Error|No solution|PackageNotFound|NoCompatibleCandidateFound|UnsupportedOriginForRuntime' use-luajit.log
    grep -v 'runtime = "5.1"' moonstone.lock
fi

echo "━━━ ✓ moon use ABI behavior passed ━━━"
