#!/usr/bin/env bash
set -euo pipefail

source "${PROJECT_ROOT}/tests/scripts/lib/assert.sh"

WORKDIR="/tmp/moonstone-contract-install"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}/project/subdir"
cd "${WORKDIR}/project"

moon init . --name install-contract --no-git
moon interpreter set lua@5.4 --no-sync
moon add inspect@3.1.3 --no-sync

cd subdir
install_json=$(moon sync --json 2>&1)
assert_json_valid "${install_json}"
assert_ndjson_terminator "${install_json}"
assert_last_json_field "${install_json}" "kind" "RESULT"
assert_last_json_field "${install_json}" "value" "sync.complete"
python3 -c 'import json, sys
messages = [json.loads(line) for line in sys.stdin if line.strip()]
assert all(message["contract"] == "moonstone:cli-events:v1" for message in messages), messages
assert all(message.get("run_id") for message in messages), messages
summary = messages[-1]["data"]["summary"]
expected = ["requested_targets", "resolved_packages", "store_hits", "downloads", "materializations", "path_link_projections", "linked", "env_refreshed", "resolve_ms", "materialize_ms", "link_ms", "total_ms"]
missing = [field for field in expected if field not in summary]
assert not missing, f"missing sync summary fields: {missing}"
assert summary["requested_targets"] >= 2, summary
assert summary["resolved_packages"] >= 1, summary
assert summary["env_refreshed"] is True, summary' <<<"${install_json}"
assert_file_contains "${WORKDIR}/project/moonstone.lock" 'name = "inspect"'
assert_file_contains "${WORKDIR}/project/moonstone.lock" 'version = "3.1.3"'

reinstall_json=$(moon sync --json 2>&1)
assert_json_valid "${reinstall_json}"
assert_ndjson_terminator "${reinstall_json}"
assert_last_json_field "${reinstall_json}" "kind" "RESULT"
python3 -c 'import json, sys
messages = [json.loads(line) for line in sys.stdin if line.strip()]
summary = messages[-1]["data"]["summary"]
assert summary["store_hits"] >= 1, summary
assert summary["linked"] >= 1, summary' <<<"${reinstall_json}"

quiet_output=$(moon sync --quiet 2>&1)
test -z "${quiet_output}"

invalid_jobs_json=$(moon sync --json --jobs 0 2>&1 || true)
assert_json_valid "${invalid_jobs_json}"
assert_ndjson_terminator "${invalid_jobs_json}"
assert_last_json_field "${invalid_jobs_json}" "kind" "ERROR"
assert_last_json_field "${invalid_jobs_json}" "value" "error.InvalidJobs"

# Add a dependency to moonstone.toml that is NOT in the lockfile.
# Now that all deps use [[dependencies]] format, we can safely append
# another [[dependencies]] entry without TOML format conflicts.
printf '\n[[dependencies]]\nname = "luassert"\nconstraint = "^1.9.0"\nrole = "runtime"\n' >> "${WORKDIR}/project/moonstone.toml"
if moon sync --locked >/tmp/moonstone-contract-install-locked.out 2>&1; then
  echo "✗ locked sync should fail when manifest and lock disagree"
  cat /tmp/moonstone-contract-install-locked.out
  exit 1
fi
assert_contains "$(cat /tmp/moonstone-contract-install-locked.out)" "moonstone.lock is out of sync" "locked sync error"

cd /tmp
if moon sync >/tmp/moonstone-contract-install-outside.out 2>&1; then
  echo "✗ sync outside project should fail"
  exit 1
fi
assert_contains "$(cat /tmp/moonstone-contract-install-outside.out)" "not inside a Moonstone project" "sync outside project error"
