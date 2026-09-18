#!/usr/bin/env bash
# No -e for the same reason as completions_delegate.sh: completion functions
# routinely hit expected non-zero exits as ordinary control flow.
set -uo pipefail

# Test: `moon exec --global -- <tool>`'s ZSH completion actually reaches a
# delegate tool's own `--__moonstone-complete-script zsh` protocol and
# registers real candidates, driving the REAL generated `moon completions
# zsh` output (not a hand-copied one) exactly like completions_delegate.sh
# does for bash.
#
# This specifically regression-tests a real bug found interactively: `_moon`
# (completions.zig's generateZsh) resolves the delegate's own materialized
# PATH via `local PATH="$(moon env --paths ...):$PATH"` before invoking the
# delegate's `--__moonstone-complete-script` protocol. In zsh, `local
# PATH=...` (without the export flag) shadows the parameter for zsh's OWN
# builtin lookups but does NOT propagate into the process environment --
# so when the delegate itself is a launcher that `exec`s a helper found only
# via a moon-managed PATH entry (mirroring hydronium-create's `exec luajit`,
# which is `luajit` resolved only through the isolated runtime's bin dir),
# that real child process falls back to a bare default PATH and fails with
# "command not found", silently producing zero completions system-wide.
# `local -x PATH=...` (or `export PATH=...`) is required. This test's fake
# delegate reproduces that exact shape: its own `--__moonstone-complete-
# script` branch execs a helper that exists ONLY in the moon-managed env bin
# dir, never on the ambient shell PATH.
#
# Real interactive TAB-completion (ZLE) can't be driven headlessly without a
# pty; instead this sources the real generated script and calls `_moon`
# directly with `words`/`CURRENT` set exactly as zsh's completion system
# would set them, and stubs `compadd`/`_normal` to capture what candidates
# would actually be offered -- proven correct against a real interactive
# `expect`-driven reproduction during development of this fix.

if ! command -v zsh >/dev/null 2>&1; then
  echo "⚠ zsh not available, skipping completions_zsh_delegate.sh" >&2
  exit 0
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"
WORKDIR="$(mktemp -d /tmp/moonstone-completions-zsh-delegate.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT

mkdir -p "${WORKDIR}/.moonstone/env/bin"
cat > "${WORKDIR}/moonstone.toml" <<'TOML'
manifest_version = 2

[package]
name = "completions-zsh-delegate-test"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"
TOML

cat > "${WORKDIR}/.moonstone/env/env.toml" <<'TOML'
[runtime]
name = "lua"
version = "5.4.7"
abi = "lua54"
TOML

# A helper that exists ONLY in the moon-managed env bin dir -- never on the
# ambient shell PATH -- mirroring `luajit` being resolvable only through the
# isolated runtime's own bin dir for a global tool like hydronium-create.
cat > "${WORKDIR}/.moonstone/env/bin/only-in-moon-env-helper" <<'SH'
#!/usr/bin/env sh
cat <<'SCRIPT'
#compdef zsh-delegate-tool
_zsh_delegate_tool_complete() {
  compadd -- --alpha --beta
}
compdef _zsh_delegate_tool_complete zsh-delegate-tool
SCRIPT
SH
chmod +x "${WORKDIR}/.moonstone/env/bin/only-in-moon-env-helper"

# The delegate tool itself: a launcher that `exec`s the helper above by bare
# name, relying on PATH resolution exactly like hydronium-create's real
# launcher does for `luajit`.
cat > "${WORKDIR}/.moonstone/env/bin/zsh-delegate-tool" <<'SH'
#!/usr/bin/env sh
if [ "$1" = "--__moonstone-complete-script" ]; then
  exec only-in-moon-env-helper
fi
echo "ran for real: $*"
SH
chmod +x "${WORKDIR}/.moonstone/env/bin/zsh-delegate-tool"

cd "${WORKDIR}"

"${MOON_BIN}" completions zsh > moon_completions.zsh

# Assert the fix is actually present in the generated script, not just that
# the end-to-end behavior happens to work for some other reason.
if ! grep -q 'local -x PATH=' moon_completions.zsh; then
  echo "Fail: expected generated zsh completions to export PATH (local -x PATH=...) before invoking a delegate's own completion protocol" >&2
  exit 1
fi

# Deliberately does NOT put "${WORKDIR}/.moonstone/env/bin" on this outer
# PATH -- that must come exclusively from `_moon`'s own internal `moon env
# --paths` PATH prepend, which is exactly the mechanism under test. Only
# ambient system paths (needed for zsh itself, compinit, sed, etc.) go here.
RESULT="$(zsh -f <<ZSH
autoload -Uz compinit
compinit -u -C
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:\$PATH"
moon() { "${MOON_BIN}" "\$@"; }
source ./moon_completions.zsh

compadd() { print -- "COMPADD:\$@"; }

words=(moon exec -- zsh-delegate-tool "")
CURRENT=5
_moon
ZSH
)"

if [[ "${RESULT}" != *"COMPADD:-- --alpha --beta"* ]]; then
  echo "Fail: expected _moon's zsh delegate branch to reach zsh-delegate-tool's own --__moonstone-complete-script protocol (via a PATH-only-resolvable helper) and register '--alpha --beta'" >&2
  echo "got: ${RESULT}" >&2
  exit 1
fi

echo "━━━ ✓ moon completions zsh delegate test passed ━━━"
