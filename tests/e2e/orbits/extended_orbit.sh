#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="/tmp/moonstone-test-extended-orbit"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

mkdir -p "deep/nested/child"

cat <<EOF > moonstone.toml
manifest_version = 2

[package]
name = "orbit-root"
kind = "script"
version = "0.1.0"

[interpreter]
name = "lua"
version = "5.4.7"

[[orbits.member]]
name = "child"
path = "deep/nested/child"
EOF

cat <<EOF > deep/nested/child/moonstone.toml
manifest_version = 2

[package]
name = "child"
kind = "script"
version = "0.1.0"

[interpreter]
name = "luajit"
version = "2.1.1783773675"

[scripts]
test-script = "luajit -e 'print(_VERSION)'"
EOF

# Sync child explicitly against the local deterministic registry.
moon --orbit child registry add moonstone "$MOONSTONE_REGISTRY_PATH" >/dev/null
moon --orbit child sync

echo "Testing explicit locked orbit sync..."
moon --orbit child sync --locked

echo "Testing that child uses luajit..."
OUTPUT=$(moon --orbit child exec -- lua -e 'print(_VERSION)' 2>&1)
if [[ "$OUTPUT" != *"LuaJIT"* ]]; then
    echo "Fail: Expected luajit, got $OUTPUT"
    exit 1
fi

echo "Testing completions for orbit command..."
OUTPUT=$(moon completions --complete "moon orbit ")
if [[ "$OUTPUT" != *"list"* ]] || [[ "$OUTPUT" == *"exec"* ]] || [[ "$OUTPUT" == *"sync"* ]]; then
    echo "Fail: Expected subcommands in moon orbit completions, got $OUTPUT"
    exit 1
fi

echo "Testing completions for orbit run..."
OUTPUT=$(moon completions --complete "moon --orbit ")
if [[ "$OUTPUT" != *"child"* ]]; then
    echo "Fail: Expected 'child' in orbit run completions, got $OUTPUT"
    exit 1
fi

echo "Testing completions for scripts inside orbit..."
OUTPUT=$(moon completions --complete "moon --orbit child run ")
if [[ "$OUTPUT" != *"test-script"* ]]; then
    echo "Fail: Expected 'test-script' in script completions, got $OUTPUT"
    exit 1
fi

echo "All extended orbit tests passed."
