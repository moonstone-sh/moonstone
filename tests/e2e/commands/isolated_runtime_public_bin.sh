#!/usr/bin/env bash
set -euo pipefail

# Test: Public/runtime-role binaries from store artifacts with an isolated runtime
# that differs from the project runtime get a bin-runtime scope so `moon exec`
# prepends the correct runtime bin directory.
#
# The synthetic registry contains a bin package `synthetic-isolated-bin` that
# declares runtime `luajit@2.1.1783773675` while the app uses `lua@5.4.7`.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="$(mktemp -d /tmp/moonstone-isolated-public-bin.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "$WORKDIR/app"

# Create the app with lua@5.4.7 and add the isolated bin package as a runtime dependency.
(cd "$WORKDIR/app" && moon init . --name my-app --no-git --no-sync)
(cd "$WORKDIR/app" && moon interpreter set lua@5.4.7 --no-sync)
(cd "$WORKDIR/app" && moon add synthetic-isolated-bin)

# Verify the public bin scope env.toml exists and prepends the isolated luajit bin directory.
SCOPE="$WORKDIR/app/.moonstone/env/bin-runtime/synthetic-isolated-bin/env.toml"
if [[ ! -f "$SCOPE" ]]; then
    echo "expected $SCOPE to exist" >&2
    ls -la "$WORKDIR/app/.moonstone/env/bin-runtime/" >&2
    exit 1
fi

if ! grep -q "luajit-2.1.1783773675/files/bin" "$SCOPE"; then
    echo "expected $SCOPE to prepend the isolated luajit bin directory" >&2
    cat "$SCOPE" >&2
    exit 1
fi

# Verify the bin actually runs with the isolated runtime.
OUTPUT="$(cd "$WORKDIR/app" && moon exec synthetic-isolated-bin)"
if [[ "$OUTPUT" != "hello from isolated synthetic bin" ]]; then
    echo "unexpected bin output: $OUTPUT" >&2
    exit 1
fi

# Removing the dependency must not replay the stale locked package.
(cd "$WORKDIR/app" && moon remove synthetic-isolated-bin)
if grep -q "synthetic-isolated-bin" "$WORKDIR/app/moonstone.toml"; then
    echo "expected synthetic-isolated-bin to be removed from moonstone.toml" >&2
    cat "$WORKDIR/app/moonstone.toml" >&2
    exit 1
fi
(cd "$WORKDIR/app" && moon sync)

echo "━━━ ✓ isolated runtime public bin test passed ━━━"
