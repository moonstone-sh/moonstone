#!/usr/bin/env bash
# No -e for the same reason as completions_delegate.sh: completion functions
# routinely hit expected non-zero exits (compgen with no matches, `complete
# -p` on something not yet registered) as ordinary control flow.
set -uo pipefail

# Test: `moon exec`'s bash completion for a role="tool" dependency that is
# actually isolated into `.moonstone/env/bin-runtime/<name>/` (its own
# runtime differs from the consuming project's), the gap completions.zig's
# old boundary/PATH/`command -v` logic could never see at all:
#   - command-name completion must include the tool via the new
#     `moon env --bin-runtime-names` merge, not just flat PATH scanning.
#   - delegate-argument completion must resolve the tool via
#     `moon provision resolve --json`, not a naive `command -v`.
#
# IMPORTANT, discovered while writing this test (read before "fixing" it):
# in this codebase's current linker.zig, EVERY role="tool" dependency also
# gets a flat `.moonstone/env/bin/<name>` shim now, unconditionally --
# `bin-runtime/<name>/` is layered on ADDITIONALLY as PATH/LUA_PATH-prepend
# metadata for `moon exec`, not as a replacement for the flat shim. That
# means a bin-runtime-scoped tool is, today, also always flat-PATH
# discoverable, so a black-box completion test can't prove candidates came
# *exclusively* from the bin-runtime-names merge by candidate-set alone.
# This test therefore verifies the underlying primitives directly
# (`moon env --bin-runtime-names`, `moon provision resolve --json`) AND
# that the completion pipeline built on top of them produces the right
# answer -- rather than overclaiming exclusivity a black-box check can't
# actually demonstrate. This is a property of already-fixed, out-of-scope
# code (linker.zig), not of the completions.zig change under test here.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi
# install_synthetic.sh sets -e (and its own pipefail); the completion
# functions exercised below routinely return non-zero as ordinary control
# flow (see the top-of-file comment), so explicitly drop back to just -u/
# pipefail, matching completions_delegate.sh's own harness settings.
set +e
set -uo pipefail
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"

WORKDIR="$(mktemp -d /tmp/moonstone-completions-bin-runtime.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT

# --- Fixture A: a STORE-provisioned role="tool" dependency whose declared
# runtime (luajit@2.1.1783773675) differs from the consuming project's own
# (lua@5.4.7) -- mirrors isolated_runtime_public_bin.sh's setup but adds
# `--tool`, mirroring tool_role_flat_bin.sh's setup but keeps the runtime
# mismatched instead of matched, so isolation actually triggers.
mkdir -p "${WORKDIR}/app-store"
(cd "${WORKDIR}/app-store" && "${MOON_BIN}" init . --name my-app --no-git --no-sync >/dev/null)
(cd "${WORKDIR}/app-store" && "${MOON_BIN}" interpreter set lua@5.4.7 --no-sync >/dev/null)
(cd "${WORKDIR}/app-store" && "${MOON_BIN}" add synthetic-isolated-bin --tool >/dev/null)

SCOPE="${WORKDIR}/app-store/.moonstone/env/bin-runtime/synthetic-isolated-bin/env.toml"
if [[ ! -f "${SCOPE}" ]]; then
    echo "Fail: expected ${SCOPE} to exist (isolation should trigger on runtime mismatch)" >&2
    exit 1
fi

# The underlying primitive completions.zig's fix depends on: listing names
# isolated under bin-runtime/.
BIN_RUNTIME_NAMES="$(cd "${WORKDIR}/app-store" && "${MOON_BIN}" env --bin-runtime-names)"
if [[ "${BIN_RUNTIME_NAMES}" != *"synthetic-isolated-bin"* ]]; then
    echo "Fail: expected 'moon env --bin-runtime-names' to list synthetic-isolated-bin" >&2
    echo "got: ${BIN_RUNTIME_NAMES}" >&2
    exit 1
fi

# The other underlying primitive: resolving it offline to a real path,
# whether or not it also happens to have a flat shim.
RESOLVE_JSON="$(cd "${WORKDIR}/app-store" && "${MOON_BIN}" provision resolve --json -- synthetic-isolated-bin 2>/dev/null)"
if [[ "${RESOLVE_JSON}" != *'"contract":"moonstone:tool-resolve:v1"'* ]] || [[ "${RESOLVE_JSON}" != *'"path":"'* ]]; then
    echo "Fail: expected 'moon provision resolve --json -- synthetic-isolated-bin' to succeed" >&2
    echo "got: ${RESOLVE_JSON}" >&2
    exit 1
fi

# Now drive the REAL generated bash completion script exactly like
# completions_delegate.sh does, from inside this project.
(cd "${WORKDIR}/app-store" && "${MOON_BIN}" completions bash > moon_completions.bash)
(
  cd "${WORKDIR}/app-store"
  source ./moon_completions.bash
  moon() { "${MOON_BIN}" "$@"; }

  # Command-name completion (typed right after the mandatory '--') must
  # include the bin-runtime-isolated tool.
  COMP_WORDS=(moon exec -- synthetic)
  COMP_CWORD=3
  COMP_LINE="moon exec -- synthetic"
  COMP_POINT=${#COMP_LINE}
  COMPREPLY=()
  _moon_completions
  found=0
  for c in "${COMPREPLY[@]}"; do
    [[ "$c" == "synthetic-isolated-bin" ]] && found=1
  done
  if [[ "$found" -ne 1 ]]; then
    echo "Fail: command-name completion for 'moon exec -- synthetic' did not include synthetic-isolated-bin" >&2
    echo "got: ${COMPREPLY[*]:-<empty>}" >&2
    exit 1
  fi
)
store_status=$?
if [[ "$store_status" -ne 0 ]]; then
  exit 1
fi

# --- Fixture B: a live-link (`moon link` + role="tool") dependency with a
# genuinely differing runtime, mirroring isolated_runtime_path_tool.sh. Its
# own main.lua implements --__moonstone-complete-script, so delegate-argument
# completion can be verified end-to-end.
#
# NOTE: live-link dependencies are locked with `artifact_hash = "link"`, not
# a real content-addressed "b3:..." hash, so `moon provision resolve` cannot
# resolve them (resolveFromRealizedEnvironment requires a "b3:" artifact
# hash) -- confirmed empirically while writing this test. This is a
# legitimate, correctly-handled case: the shell code's designed fallback to
# `command -v` (which finds the tool's own always-flat-projected shim, see
# the note above) is exactly what should -- and does -- happen here. This
# fixture therefore exercises the fallback path, while Fixture A above
# exercises the `moon provision resolve`-succeeds path.
mkdir -p "${WORKDIR}/tool/src" "${WORKDIR}/app-link"
cat > "${WORKDIR}/tool/moonstone.toml" <<'TOML'
manifest_version = 2

[package]
name = "linked-completion-tool"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4.6"
abi = "5.4"
TOML

cat > "${WORKDIR}/tool/src/main.lua" <<'LUA'
if arg[1] == "--__moonstone-complete-script" then
  print([[
_linked_completion_tool_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=( $(compgen -W "--widget --gadget" -- "$cur") )
}
complete -F _linked_completion_tool_complete linked-completion-tool
]])
  os.exit(0)
end
print("ran for real")
LUA

(cd "${WORKDIR}/tool" && "${MOON_BIN}" link >/dev/null)
(cd "${WORKDIR}/app-link" && "${MOON_BIN}" init . --name my-app --no-git --no-sync >/dev/null)
(cd "${WORKDIR}/app-link" && "${MOON_BIN}" interpreter set lua@5.4.7 --no-sync >/dev/null)
cat > "${WORKDIR}/app-link/moonstone.toml" <<'TOML'
manifest_version = 2

[package]
name = "my-app"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4.7"
abi = "5.4"

[[dependencies]]
name = "linked-completion-tool"
constraint = "link:linked-completion-tool"
role = "tool"
TOML
(cd "${WORKDIR}/app-link" && "${MOON_BIN}" sync >/dev/null)

SCOPE2="${WORKDIR}/app-link/.moonstone/env/bin-runtime/linked-completion-tool/env.toml"
if [[ ! -f "${SCOPE2}" ]]; then
    echo "Fail: expected ${SCOPE2} to exist" >&2
    exit 1
fi
BIN_RUNTIME_NAMES2="$(cd "${WORKDIR}/app-link" && "${MOON_BIN}" env --bin-runtime-names)"
if [[ "${BIN_RUNTIME_NAMES2}" != *"linked-completion-tool"* ]]; then
    echo "Fail: expected 'moon env --bin-runtime-names' to list linked-completion-tool" >&2
    echo "got: ${BIN_RUNTIME_NAMES2}" >&2
    exit 1
fi

(cd "${WORKDIR}/app-link" && "${MOON_BIN}" completions bash > moon_completions.bash)
(
  cd "${WORKDIR}/app-link"
  source ./moon_completions.bash
  moon() { "${MOON_BIN}" "$@"; }

  COMP_WORDS=(moon exec -- linked-completion-tool "")
  COMP_CWORD=4
  COMP_LINE="moon exec -- linked-completion-tool "
  COMP_POINT=${#COMP_LINE}
  COMPREPLY=()
  _moon_completions
  if [[ "${COMPREPLY[*]:-}" != "--widget --gadget" ]]; then
    echo "Fail: expected delegate completion to reach linked-completion-tool's own --__moonstone-complete-script" >&2
    echo "got: ${COMPREPLY[*]:-<empty>}" >&2
    exit 1
  fi
)
link_status=$?
if [[ "$link_status" -ne 0 ]]; then
  exit 1
fi

echo "━━━ ✓ moon completions bin-runtime delegate test passed ━━━"
