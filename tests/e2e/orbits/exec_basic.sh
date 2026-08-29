#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

MOON_BIN="${MOON_BIN:-${PROJECT_ROOT}/zig-out/bin/moon}"

WORKDIR="/tmp/moonstone-test-orbit-exec"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

mkdir -p "child"

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
path = "child"
EOF

cat <<EOF > child/moonstone.toml
manifest_version = 2

[package]
name = "child"
kind = "script"
version = "0.1.0"

[interpreter]
name = "lua"
version = "5.4.7"

[scripts]
hello = "lua hello.lua"
EOF

cat <<EOF > child/hello.lua
print("hello from child")
EOF

cat <<EOF > file.txt
root
EOF

cat <<EOF > child/file.txt
child
EOF

# Sync child explicitly
"$MOON_BIN" orbit sync child

# 1. Orbit exec runs inside child env
echo "Testing orbit exec runs inside child env..."
OUTPUT=$("$MOON_BIN" orbit exec child lua -e 'print("orbit:" .. _VERSION)')
if [[ "$OUTPUT" != *"orbit:Lua 5.4"* ]]; then
    echo "Fail: Expected orbit:Lua 5.4, got $OUTPUT"
    exit 1
fi

# 2. Orbit run executes child script
echo "Testing orbit run executes child script..."
OUTPUT=$("$MOON_BIN" orbit run child hello)
if [[ "$OUTPUT" != *"hello from child"* ]]; then
    echo "Fail: Expected hello from child, got $OUTPUT"
    exit 1
fi

# 3. Orbit exec does not use root cwd
echo "Testing orbit exec does not use root cwd..."
OUTPUT=$("$MOON_BIN" orbit exec child lua -e 'local f=io.open("file.txt"); print(f:read("*a"))')
if [[ "$OUTPUT" != *"child"* ]]; then
    echo "Fail: Expected child, got $OUTPUT"
    exit 1
fi

# 4. Selector by path works
echo "Testing selector by path..."
OUTPUT=$("$MOON_BIN" orbit exec ./child lua -e 'print("ok")')
if [[ "$OUTPUT" != *"ok"* ]]; then
    echo "Fail: Expected ok, got $OUTPUT"
    exit 1
fi

# 5. Direct `orbit exec` without `--` succeeds
echo "Testing orbit exec without --..."
OUTPUT=$("$MOON_BIN" orbit exec child lua -e 'print("no-dash-dash-ok")')
if [[ "$OUTPUT" != *"no-dash-dash-ok"* ]]; then
    echo "Fail: Expected no-dash-dash-ok, got $OUTPUT"
    exit 1
fi

# 6. Unknown orbit fails clearly
echo "Testing unknown orbit..."
if "$MOON_BIN" orbit run does-not-exist hello >/dev/null 2>&1; then
    echo "Fail: Expected unknown orbit to fail"
    exit 1
fi

# 7. Cwd restoration
echo "Testing cwd restoration..."
# After an orbit command fails, another root-relative operation should still work from the original root cwd.
"$MOON_BIN" orbit run does-not-exist hello >/dev/null 2>&1 || true
# We should still be in $PROJECT_DIR
if [ ! -f "moonstone.toml" ] || [ ! -f "file.txt" ]; then
    echo "Fail: CWD was not restored after failure!"
    exit 1
fi
if [ "$(cat file.txt)" != "root" ]; then
    echo "Fail: file.txt does not contain root! Cwd is messed up."
    exit 1
fi

echo "All orbit execution tests passed."
