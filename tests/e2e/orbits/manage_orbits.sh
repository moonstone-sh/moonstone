#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="$(mktemp -d /tmp/moonstone-manage-orbits.XXXXXX)"
OUTSIDE_DIR="$(mktemp -d /tmp/moonstone-outside-orbit.XXXXXX)"
trap 'rm -rf "${WORKDIR}" "${OUTSIDE_DIR}"' EXIT

mkdir -p "${WORKDIR}/nested/child" "${WORKDIR}/empty" "${OUTSIDE_DIR}/child"

cat > "${WORKDIR}/moonstone.toml" <<'TOML'
[package]
name = "orbit-root"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[build.env]
OPENSSL_DIR = "/tmp/moonstone-openssl"
CC = { from = "CC", optional = true, default = "zig cc" }
TOML

cat > "${WORKDIR}/nested/child/moonstone.toml" <<'TOML'
[package]
name = "orbit-child"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"
TOML

cat > "${OUTSIDE_DIR}/child/moonstone.toml" <<'TOML'
[package]
name = "outside-child"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"
TOML

cd "${WORKDIR}"
moon orbit add --name child --path nested/child
grep -q '\[\[orbits.member\]\]' moonstone.toml
grep -q 'name = "child"' moonstone.toml
grep -q 'path = "nested/child"' moonstone.toml
grep -q '\[build.env\]' moonstone.toml
grep -q '"OPENSSL_DIR" = "/tmp/moonstone-openssl"' moonstone.toml
grep -q '"CC" = { from = "CC", optional = true, default = "zig cc" }' moonstone.toml
moon orbit list | grep -q 'child'
moon completions --complete "moon orbit add --path " | grep -q 'nested/child'
moon completions --complete "moon orbit remove " | grep -q 'child'
moon completions --complete "moon orbit remove ch" | grep -qx 'child'

if moon orbit add --name duplicate-name --path nested/child >/tmp/moonstone-orbit-duplicate-path.log 2>&1; then
    echo "ERROR: duplicate orbit path was accepted"
    exit 1
fi
grep -q 'already uses this child project path' /tmp/moonstone-orbit-duplicate-path.log

if moon orbit add --name empty --path empty >/tmp/moonstone-orbit-missing-manifest.log 2>&1; then
    echo "ERROR: directory without moonstone.toml was accepted"
    exit 1
fi
grep -q 'must contain a valid moonstone.toml' /tmp/moonstone-orbit-missing-manifest.log

if moon orbit add --name outside --path "${OUTSIDE_DIR}/child" >/tmp/moonstone-orbit-outside.log 2>&1; then
    echo "ERROR: outside orbit path was accepted"
    exit 1
fi
grep -q 'must be a subdirectory' /tmp/moonstone-orbit-outside.log

moon orbit sync child
moon orbit remove child
if grep -q '\[\[orbits.member\]\]' moonstone.toml; then
    echo "ERROR: orbit declaration remained after removal"
    exit 1
fi
grep -q '\[build.env\]' moonstone.toml
grep -q '"OPENSSL_DIR" = "/tmp/moonstone-openssl"' moonstone.toml
grep -q '"CC" = { from = "CC", optional = true, default = "zig cc" }' moonstone.toml
if moon completions --complete "moon orbit remove " | grep -q 'child'; then
    echo "ERROR: removed orbit remained in completion results"
    exit 1
fi

echo "━━━ ✓ Orbit add/remove validation passed ━━━"
