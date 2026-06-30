#!/usr/bin/env bash
set -euo pipefail

# Test: Tool-scope packages with an isolated runtime get that runtime prepended to PATH.
# A path-linked tool declares runtime lua@5.4.6 while the app uses lua@5.4.7.
# After sync, the tool's bin-runtime scope must include the lua@5.4.6 bin directory.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="$(mktemp -d /tmp/moonstone-isolated-runtime.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "$WORKDIR/tool/src" "$WORKDIR/app"

cat > "$WORKDIR/tool/moonstone.toml" <<'TOML'
[package]
name = "linked-tool"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4.6"
abi = "5.4"
TOML

cat > "$WORKDIR/tool/src/main.lua" <<'LUA'
print("hello from isolated tool")
LUA

# Register the linked tool
(cd "$WORKDIR/tool" && moon link)

# Create the app with a different runtime and add the linked tool as a tool-scope dependency
(cd "$WORKDIR/app" && moon init . --name my-app --no-git --no-sync)
(cd "$WORKDIR/app" && moon interpreter set lua@5.4.7 --no-sync)

cat > "$WORKDIR/app/moonstone.toml" <<'TOML'
[package]
name = "my-app"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4.7"
abi = "5.4"

[dependencies.tool]
"linked-tool" = "link:linked-tool"

[scripts]
"hello" = "lua -e 'print(\"hello from app\")'"
TOML

# Sync must resolve and materialize the tool's isolated lua@5.4.6 runtime.
(cd "$WORKDIR/app" && moon sync)

# Verify the tool scope env.toml prepends the isolated runtime bin directory.
SCOPE="$WORKDIR/app/.moonstone/env/bin-runtime/linked-tool/env.toml"
if [[ ! -f "$SCOPE" ]]; then
    echo "expected $SCOPE to exist" >&2
    ls -la "$WORKDIR/app/.moonstone/env/bin-runtime/" >&2
    exit 1
fi

if ! grep -q "lua-5.4.6/files/bin" "$SCOPE"; then
    echo "expected $SCOPE to prepend the isolated lua@5.4.6 bin directory" >&2
    cat "$SCOPE" >&2
    exit 1
fi

# Verify the tool actually runs with its isolated runtime.
OUTPUT="$(cd "$WORKDIR/app" && moon exec linked-tool)"
if [[ "$OUTPUT" != "hello from isolated tool" ]]; then
    echo "unexpected tool output: $OUTPUT" >&2
    exit 1
fi

echo "━━━ ✓ isolated runtime path tool test passed ━━━"
