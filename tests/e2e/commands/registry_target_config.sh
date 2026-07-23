#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="$(mktemp -d /tmp/moonstone-registry-target.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT

mkdir -p "${WORKDIR}/project"
cat > "${WORKDIR}/config.toml" <<TOML
[paths]
home_directory = "${WORKDIR}/configured-home"

[network]
timeout = 7
retries = 1

TOML

cat > "${WORKDIR}/project/moonstone.toml" <<TOML
[package]
name = "registry-target-test"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[registries]
project = { path = "${WORKDIR}/project-registry", priority = 10 }
user = { path = "${WORKDIR}/user-registry", priority = 5 }
profiled = { path = "${WORKDIR}/profiled-registry", priority = 4 }
TOML

moon --config-file="${WORKDIR}/config.toml" config show > "${WORKDIR}/config-show.log"
grep -Fq "Config File:            ${WORKDIR}/config.toml" "${WORKDIR}/config-show.log"
grep -Fq "Data Directory:         ${WORKDIR}/configured-home/data" "${WORKDIR}/config-show.log"

moon --config-file="${WORKDIR}/config.toml" registry init --file "${WORKDIR}/user-registry" --name user --json | grep -Fq '"kind":"RESULT"'
cd "${WORKDIR}/project"
moon --config-file="${WORKDIR}/config.toml" registry user: settings show | grep -Fq 'name = "user"'
moon --config-file="${WORKDIR}/config.toml" registry user: doctor | grep -Fq 'is healthy'
moon --config-file="${WORKDIR}/config.toml" registry init --file "${WORKDIR}/profiled-registry" --name profiled --json | grep -Fq '"kind":"RESULT"'
moon --config-file="${WORKDIR}/config.toml" registry profiled: doctor | grep -Fq 'is healthy'

mkdir -p "${WORKDIR}/artifact"
printf 'return "registry target"\n' > "${WORKDIR}/artifact/module.lua"
tar -czf "${WORKDIR}/artifact.tar.gz" -C "${WORKDIR}/artifact" .
cat > "${WORKDIR}/package.toml" <<'TOML'
[package]
name = "test/target"
version = "1.0.0"
kind = "lib"
description = "first descriptor"

[[artifacts]]
id = "any"
kind = "lib"
target = "any"
format = "tar.gz"
url = "placeholder.tar.gz"
hash = "b3:placeholder"

[artifacts.materialize]
type = "archive"
TOML

moon --config-file="${WORKDIR}/config.toml" registry user: publish --descriptor "${WORKDIR}/package.toml" --artifact "${WORKDIR}/artifact.tar.gz"
moon --config-file="${WORKDIR}/config.toml" registry user: publish --update --descriptor "${WORKDIR}/package.toml" --artifact "${WORKDIR}/artifact.tar.gz" | grep -Fq 'already published'
moon --config-file="${WORKDIR}/config.toml" registry user: fetch --descriptor test/target@1.0.0 | grep -Fq 'first descriptor'
moon --config-file="${WORKDIR}/config.toml" registry user: fetch --descriptor test/target@1.0.0 --json | grep -Fq '"kind":"RESULT"'
moon --config-file="${WORKDIR}/config.toml" registry user: settings show --json | grep -Fq '"kind":"RESULT"'
moon --config-file="${WORKDIR}/config.toml" registry user: doctor --json | grep -Fq '"kind":"RESULT"'
mkdir -p "${WORKDIR}/incomplete-registry"
if moon registry --file "${WORKDIR}/incomplete-registry" doctor --json >"${WORKDIR}/doctor-error.json" 2>&1; then
    echo "registry doctor accepted an incomplete registry" >&2
    exit 1
fi
grep -Fq '"kind":"ERROR"' "${WORKDIR}/doctor-error.json"
grep -Fq '"terminator":true' "${WORKDIR}/doctor-error.json"
sed -i.bak 's/first descriptor/changed descriptor/' "${WORKDIR}/package.toml"
if moon --config-file="${WORKDIR}/config.toml" registry user: publish --descriptor "${WORKDIR}/package.toml" --artifact "${WORKDIR}/artifact.tar.gz" >/dev/null 2>&1; then
    echo "registry accepted an immutable version overwrite" >&2
    exit 1
fi

moon registry project: auth --file ./project.auth.lua --json | grep -Fq '"kind":"RESULT"'
grep -Fq 'credential_provider = "./project.auth.lua"' moonstone.toml
grep -Fxq '*.auth.lua' .gitignore
moon --config-file="${WORKDIR}/config.toml" completions --complete "moon registry " > "${WORKDIR}/completions"
grep -qx 'user:' "${WORKDIR}/completions"
grep -qx 'profiled:' "${WORKDIR}/completions"
grep -qx 'project:' "${WORKDIR}/completions"
moon --config-file="${WORKDIR}/config.toml" completions --complete "moon registry project: " | grep -qx 'publish'

echo "━━━ ✓ Config-file registry target grammar passed ━━━"
