#!/usr/bin/env bash
set -euo pipefail

# Test: role="tool" dependencies whose declared runtime MATCHES the consuming
# project's own interpreter must still be flat-projected into
# `.moonstone/env/bin/` (so `which <name>` / PATH / shell completion can find
# them), not isolated into a bin-runtime scope. Isolation is only needed when
# the runtimes actually differ (covered by isolated_runtime_path_tool.sh).
#
# Before this fix, ALL role="tool" dependencies got bin-runtime-ONLY
# treatment unconditionally, even when their own runtime was identical to the
# project's — this test locks in the fix (linker.zig's tool_bin_map handling
# now mirrors the public_bin_map handling: always flat-project, and only
# additionally isolate when needed).
#
# Reuses the existing synthetic-isolated-bin package (declares runtime
# luajit@2.1.1783773675) but sets the CONSUMING project's own interpreter to
# that exact same synthetic luajit runtime, so no isolation is actually
# required — unlike isolated_runtime_public_bin.sh, which deliberately keeps
# the project on a different runtime (lua@5.4.7) to exercise the isolated
# case.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="$(mktemp -d /tmp/moonstone-tool-role-flat-bin.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "$WORKDIR/app"

# Create the app using the SAME synthetic luajit runtime that
# synthetic-isolated-bin itself declares, then add it as a role="tool"
# dependency.
(cd "$WORKDIR/app" && moon init . --name my-app --no-git --no-sync)
(cd "$WORKDIR/app" && moon interpreter set luajit@2.1.1783773675 --no-sync)
(cd "$WORKDIR/app" && moon add synthetic-isolated-bin --tool)

# (a) The binary must be flat-projected into .moonstone/env/bin/, exactly
# like a public bin — `which`/PATH/shell completion can find it.
FLAT_BIN="$WORKDIR/app/.moonstone/env/bin/synthetic-isolated-bin"
if [[ ! -x "$FLAT_BIN" ]]; then
    echo "expected $FLAT_BIN to exist and be executable" >&2
    ls -la "$WORKDIR/app/.moonstone/env/bin/" >&2
    exit 1
fi

# (c) No isolated bin-runtime scope should have been written: the runtimes
# match, so no isolation is needed.
SCOPE="$WORKDIR/app/.moonstone/env/bin-runtime/synthetic-isolated-bin/env.toml"
if [[ -f "$SCOPE" ]]; then
    echo "expected $SCOPE to NOT exist (runtimes match; no isolation needed)" >&2
    cat "$SCOPE" >&2
    exit 1
fi

# (b) `moon exec` must still work for a flat-projected tool binary.
#
# `--dev` is required here: flat-projecting role="tool" binaries (this fix)
# means they now go through `resolveInDirectory(run_env.bin_path, ...)` in
# exec.zig, which gates non-`--dev` execution through
# `run_env.isEnvEntryAllowed(..., .runtime)`. That allow-list (pre-existing,
# in src/core/project/run_env.zig, unrelated to this fix and out of scope
# for it) only recognizes lockfile roles "runtime"/"dev"/"libs"/"bins" — not
# "tool" — so a role="tool" dependency's flat bin is intentionally excluded
# from a bare `moon exec <name>` and needs `--dev` today. Before this fix a
# role="tool" bin was never flat-projected, so it never reached this gate at
# all (it always fell through to the bin-runtime-scope special case in
# exec.zig instead, which has no such restriction).
OUTPUT="$(cd "$WORKDIR/app" && moon exec --dev -- synthetic-isolated-bin)"
if [[ "$OUTPUT" != "LuaJIT synthetic runtime" ]]; then
    echo "unexpected bin output: $OUTPUT" >&2
    exit 1
fi

# `moon env --bin-runtime-names` must not list this tool (it isn't isolated).
BIN_RUNTIME_NAMES="$(cd "$WORKDIR/app" && moon env --bin-runtime-names)"
if [[ "$BIN_RUNTIME_NAMES" == *"synthetic-isolated-bin"* ]]; then
    echo "expected 'moon env --bin-runtime-names' to NOT list synthetic-isolated-bin" >&2
    echo "got: $BIN_RUNTIME_NAMES" >&2
    exit 1
fi

# `moon env --paths` must include the flat bin directory that now contains
# the tool binary.
PATHS_OUTPUT="$(cd "$WORKDIR/app" && moon env --paths)"
if [[ "$PATHS_OUTPUT" != *".moonstone/env/bin"* ]]; then
    echo "expected 'moon env --paths' to include the flat bin directory" >&2
    echo "got: $PATHS_OUTPUT" >&2
    exit 1
fi

echo "━━━ ✓ tool role flat bin test passed ━━━"
