#!/usr/bin/env bash
set -euo pipefail

# Test: semantic manifest script APIs remain source-preserving, transactional,
# and usable without resolving a runtime or contacting a registry.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"
WORKDIR="$(mktemp -d /tmp/moonstone-manifest-scripts.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT

cat > "${WORKDIR}/moonstone.toml" <<'TOML'
manifest_version = 2

[package]
name = "manifest-script-contract"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[scripts]
# This comment belongs to alpha.
alpha = "printf alpha"
zeta = "printf zeta"
TOML

cd "${WORKDIR}"

"${MOON_BIN}" manifest export --json | grep -Fq '"contract":"moonstone:manifest:v1"'
"${MOON_BIN}" manifest script list --json | grep -Fq '"name":"alpha"'
"${MOON_BIN}" manifest script get alpha --json | grep -Fq '"command":"printf alpha"'

"${MOON_BIN}" manifest script set beta --command "printf beta"
grep -Fq '# This comment belongs to alpha.' moonstone.toml
script_names="$(awk -F ' = ' '
  /^\[scripts\]$/ { in_scripts = 1; next }
  /^\[/ { in_scripts = 0 }
  in_scripts && /^[A-Za-z0-9_-]+ = / { print $1 }
' moonstone.toml | tr '\n' ' ')"
test "${script_names}" = "alpha beta zeta "

set +e
printf '%s' '{"contract":"moonstone:manifest-edit:v1","operations":[]}' |
  "${MOON_BIN}" manifest apply --json >/tmp/moonstone-manifest-apply-requires-force.out 2>&1
apply_status=$?
set -e
test "${apply_status}" -ne 0
grep -Fq 'ManifestApplyRequiresForce' /tmp/moonstone-manifest-apply-requires-force.out

revision="$("${MOON_BIN}" manifest export --json | sed -n 's/.*"storage_revision":"\([^"]*\)".*/\1/p')"
printf '%s' "{\"contract\":\"moonstone:manifest-edit:v1\",\"expected_revision\":\"${revision}\",\"operations\":[{\"kind\":\"set_script\",\"name\":\"gamma\",\"command\":\"printf gamma\"}]}" |
  "${MOON_BIN}" manifest apply --json --force | grep -Fq '"storage_mode":"source_preserving"'

"${MOON_BIN}" manifest script remove beta
"${MOON_BIN}" manifest tidy --check --json | grep -Fq '"changed":false'
grep -Fq '# This comment belongs to alpha.' moonstone.toml

echo "━━━ ✓ manifest script contract passed ━━━"
