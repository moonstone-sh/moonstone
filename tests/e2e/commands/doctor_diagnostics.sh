#!/usr/bin/env bash
set -euo pipefail

source "${PROJECT_ROOT}/tests/scripts/lib/assert.sh"

WORKDIR="/tmp/moonstone-contract-doctor"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}/project/subdir"
cd "${WORKDIR}/project"

moon init . --name doctor-contract --no-git
moon use lua@5.4
moon add inspect@3.1.3

cd subdir
doctor_ok=$(moon doctor 2>&1 || true)
assert_contains "${doctor_ok}" "project_root" "doctor discovers parent project"
assert_contains "${doctor_ok}" "lockfile_sync" "doctor reports lockfile sync check"

cd "${WORKDIR}/project"
printf '\n[dependencies.libs]\n"luassert" = "^1.9.0"\n' >> moonstone.toml
doctor_stale=$(moon doctor 2>&1 || true)
assert_contains "${doctor_stale}" "moonstone.lock is missing 1 manifest dependency" "doctor detects stale lockfile"

rm -f .moonstone/env/bin/lua
ln -s /tmp/moonstone-definitely-missing-lua .moonstone/env/bin/lua
doctor_broken=$(moon doctor 2>&1 || true)
assert_contains "${doctor_broken}" "broken symlink" "doctor detects broken env symlink"

doctor_json=$(moon doctor --json 2>&1 || true)
assert_json_valid "${doctor_json}"
assert_ndjson_terminator "${doctor_json}"
