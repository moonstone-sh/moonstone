#!/usr/bin/env bash
set -euo pipefail

# Test: `moon exec`/`moon orbit exec`/`moon orbit run`'s bash completion
# delegates to whatever completion is registered for the wrapped command,
# with the moon-managed bin dir added to PATH -- exactly as typing the
# wrapped command directly would, plus visibility into tools this project's
# moon environment materializes but the ambient shell PATH doesn't have.
#
# This sources the REAL generated completion script (`moon completions
# bash`), not a hand-copied one, and drives it via bash's own programmable
# completion variables (COMP_WORDS/COMP_CWORD/COMP_LINE) -- no pty needed,
# since bash completion functions are ordinary shell functions callable
# directly once those variables are set.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"
WORKDIR="$(mktemp -d /tmp/moonstone-completions-delegate.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT

mkdir -p "${WORKDIR}/.moonstone/env/bin"
cat > "${WORKDIR}/moonstone.toml" <<'TOML'
manifest_version = 2

[package]
name = "completions-delegate-test"
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

# A tool this project's moon environment materializes but that is NOT on
# the ambient shell PATH -- proves `moon env --paths` is really consulted,
# not just the caller's own PATH.
cat > "${WORKDIR}/.moonstone/env/bin/only-in-moon-env" <<'SH'
#!/usr/bin/env sh
echo ran
SH
chmod +x "${WORKDIR}/.moonstone/env/bin/only-in-moon-env"

cd "${WORKDIR}"

"${MOON_BIN}" completions bash > moon_completions.bash
source ./moon_completions.bash

# Fake `docker` and its own registered completion, to prove delegation
# reaches a real, independently-registered completion function with the
# words correctly shifted.
_docker() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  if (( COMP_CWORD == 1 )); then
    COMPREPLY=( $(compgen -W "run build" -- "$cur") )
  elif [[ "${COMP_WORDS[1]}" == "run" ]]; then
    COMPREPLY=( $(compgen -W "--rm --name" -- "$cur") )
  fi
}
complete -F _docker docker

moon() { "${MOON_BIN}" "$@"; }

check() {
  local expected="$1"; shift
  COMP_WORDS=("$@")
  COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
  COMP_LINE="${COMP_WORDS[*]}"
  COMP_POINT=${#COMP_LINE}
  COMPREPLY=()
  _moon_completions
  if [[ "${COMPREPLY[*]:-}" != "$expected" ]]; then
    echo "Fail: for '${COMP_WORDS[*]}' expected '$expected', got '${COMPREPLY[*]:-<empty>}'" >&2
    exit 1
  fi
}

# Choosing the delegate command name: sees the moon-env-only tool, filtered.
check "only-in-moon-env" moon exec only-in-moon-env

# Past the command name: delegates to docker's own completion, words shifted.
check "run build" moon exec -- docker ""
check "--rm --name" moon exec -- docker run ""

# Moon's own words are unaffected.
check "exec" moon "ex"

echo "━━━ ✓ moon completions delegation passed ━━━"
