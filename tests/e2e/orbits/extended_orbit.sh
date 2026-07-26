#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="/tmp/moonstone-test-extended-orbit"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

mkdir -p "deep/nested/child"

cat <<EOF > moonstone.toml
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
[package]
name = "child"
kind = "script"
version = "0.1.0"

[interpreter]
name = "luajit"
version = "2.1.1783773675"

[scripts]
test-script = "luajit -v"
EOF

# Sync child explicitly
moon orbit sync child

echo "Testing explicit locked orbit sync..."
moon orbit sync child --locked

echo "Testing that child uses luajit..."
OUTPUT=$(moon orbit exec child -- luajit -v 2>&1)
if [[ "$OUTPUT" != *"luajit"* ]]; then
    echo "Fail: Expected luajit, got $OUTPUT"
    exit 1
fi

echo "Testing completions for orbit command..."
OUTPUT=$(moon completions --complete "moon orbit ")
if [[ "$OUTPUT" != *"exec"* ]] || [[ "$OUTPUT" != *"run"* ]] || [[ "$OUTPUT" != *"list"* ]] || [[ "$OUTPUT" != *"sync"* ]]; then
    echo "Fail: Expected subcommands in moon orbit completions, got $OUTPUT"
    exit 1
fi

echo "Testing completions for orbit run..."
OUTPUT=$(moon completions --complete "moon orbit run ")
if [[ "$OUTPUT" != *"child"* ]]; then
    echo "Fail: Expected 'child' in orbit run completions, got $OUTPUT"
    exit 1
fi

echo "Testing completions for scripts inside orbit..."
OUTPUT=$(moon completions --complete "moon orbit run child ")
if [[ "$OUTPUT" != *"test-script"* ]]; then
    echo "Fail: Expected 'test-script' in script completions, got $OUTPUT"
    exit 1
fi

echo "All extended orbit tests passed."
