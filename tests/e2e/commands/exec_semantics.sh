#!/usr/bin/env bash
set -euo pipefail

# Test: moon exec keeps every child argument opaque once the command name is
# consumed — including any number of further "--" tokens the child wants for
# itself (e.g. `docker run x -- y`). Only a "--" appearing BEFORE the command
# name (to escape a hyphen-leading command) is ever consumed by Moonstone.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"
WORKDIR="$(mktemp -d /tmp/moonstone-exec-semantics.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT

mkdir -p "${WORKDIR}/.moonstone/env/bin"
cat > "${WORKDIR}/moonstone.toml" <<'TOML'
manifest_version = 2

[package]
name = "exec-semantics"
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

cat > "${WORKDIR}/.moonstone/env/bin/tool" <<'SH'
#!/usr/bin/env sh
printf 'TOOL'
for argument in "$@"; do printf '[%s]' "$argument"; done
printf '\n'
SH
chmod +x "${WORKDIR}/.moonstone/env/bin/tool"

cat > "${WORKDIR}/.moonstone/env/bin/-strange" <<'SH'
#!/usr/bin/env sh
printf 'STRANGE'
for argument in "$@"; do printf '[%s]' "$argument"; done
printf '\n'
SH
chmod +x "${WORKDIR}/.moonstone/env/bin/-strange"

cd "${WORKDIR}"
"${MOON_BIN}" exec tool direct | grep -Fx 'TOOL[direct]'

# A "--" AT OR AFTER the command name is now always forwarded verbatim,
# however many there are — this is the behavior a tool like docker
# (`run x -- y`) needs, and there is no way for Moonstone to tell "a
# cosmetic separator the user typed" apart from "a `--` the child's own
# argument grammar needs", so it never guesses and never drops one.
"${MOON_BIN}" exec tool -- first "two words" | grep -Fx 'TOOL[--][first][two words]'
"${MOON_BIN}" exec tool -- -- | grep -Fx 'TOOL[--][--]'
"${MOON_BIN}" exec tool x -- y | grep -Fx 'TOOL[x][--][y]'
"${MOON_BIN}" exec -- tool run x -- --something-else | grep -Fx 'TOOL[run][x][--][--something-else]'

# A "--" BEFORE the command name still escapes a hyphen-leading command name
# and is still consumed (not forwarded) — that boundary is unchanged, and is
# the only "--" Moonstone itself ever interprets.
"${MOON_BIN}" exec -- -strange arg | grep -Fx 'STRANGE[arg]'

echo "━━━ ✓ moon exec delimiter semantics passed ━━━"
