#!/usr/bin/env bash
set -euo pipefail

source "${PROJECT_ROOT}/tests/scripts/lib/assert.sh"

WORKDIR="/tmp/moonstone-contract-link-check"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}/consumer/subdir"
cp -R "${SANDBOX_DIR}/my-lib" "${WORKDIR}/my-lib"
cd "${WORKDIR}/consumer"

moon init . --name link-check-consumer --no-git
moon use lua@5.4

moon add path:../my-lib --no-sync
assert_file_contains moonstone.toml 'path = "../my-lib"'

cd subdir
moon sync
moon exec -- lua -e 'local m=require("my_lib"); print(m.greet("relative"))' | grep 'Hello, relative'

before_lock=$(cat "${WORKDIR}/consumer/moonstone.lock")
before_env=$(find "${WORKDIR}/consumer/.moonstone/env" -type l -o -type f | sort | xargs shasum 2>/dev/null || true)
moon sync --check
if [[ "$(cat "${WORKDIR}/consumer/moonstone.lock")" != "${before_lock}" ]]; then
  echo "✗ install --check changed moonstone.lock"
  exit 1
fi
after_env=$(find "${WORKDIR}/consumer/.moonstone/env" -type l -o -type f | sort | xargs shasum 2>/dev/null || true)
if [[ "${after_env}" != "${before_env}" ]]; then
  echo "✗ install --check changed .moonstone/env"
  exit 1
fi

cd "${WORKDIR}/consumer"
printf '\n[[dependencies]]\nname = "inspect"\nconstraint = "^3.1.3"\n' >> moonstone.toml
if moon sync --check >/tmp/moonstone-contract-install-check-stale.out 2>&1; then
  echo "✗ install --check should fail for stale lockfile"
  exit 1
fi
assert_contains "$(cat /tmp/moonstone-contract-install-check-stale.out)" "moonstone.lock is missing dependency inspect" "install check stale lock error"

moon add inspect@3.1.3
rm -f .moonstone/env/bin/lua
ln -s /tmp/moonstone-contract-missing-lua .moonstone/env/bin/lua
if moon sync --check >/tmp/moonstone-contract-install-check-env.out 2>&1; then
  echo "✗ install --check should fail for broken env"
  exit 1
fi
assert_contains "$(cat /tmp/moonstone-contract-install-check-env.out)" ".moonstone/env has" "install check env error"

json_out=$(moon sync --check --json 2>&1 || true)
assert_json_valid "${json_out}"
assert_ndjson_terminator "${json_out}"
assert_last_json_field "${json_out}" "kind" "ERROR"

cd "${WORKDIR}/consumer"
if moon link ../my-lib >/tmp/moonstone-contract-link-mode.out 2>&1; then
  echo "✗ moon link should reject dependency arguments"
  exit 1
fi
assert_contains "$(cat /tmp/moonstone-contract-link-mode.out)" "UnexpectedArgument" "link registration-only error"

rm -rf "${WORKDIR}/absolute-consumer"
mkdir -p "${WORKDIR}/absolute-consumer"
cd "${WORKDIR}/absolute-consumer"
moon init . --name absolute-consumer --no-git
moon add "path:${WORKDIR}/my-lib" --no-sync
assert_file_contains moonstone.toml "path:${WORKDIR}/my-lib"
