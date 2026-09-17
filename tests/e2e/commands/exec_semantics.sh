#!/usr/bin/env bash
set -euo pipefail

# Test: moon exec requires a mandatory, single-purpose "--" before the
# wrapped <command>. Once seen, moonstone stops parsing its own flags and
# forwards every remaining token opaquely — including any number of further
# "--" tokens the child wants for itself (e.g. `docker run x -- y`). Without
# a "--" at all, moonstone can no longer tell where its own option parsing
# ends, so it must fail clearly instead of guessing from positional count.

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

# A bare command with no "--" at all can no longer succeed: moonstone has no
# way left to infer where its own option parsing ends and the wrapped
# command begins (the old positional-counting fallback is gone).
if OUTPUT=$("${MOON_BIN}" exec tool direct 2>&1); then
    echo "Fail: expected 'moon exec' without '--' to fail, got: ${OUTPUT}" >&2
    exit 1
fi
echo "${OUTPUT}" | grep -Fq -- "--"

# The mandatory "--" precedes <command>. Once seen, every remaining token —
# including any further "--" the child wants for itself — is forwarded
# verbatim, however many there are (e.g. `moon exec -- docker run x -- y`
# gives docker exactly `run x -- y`).
"${MOON_BIN}" exec -- tool first "two words" | grep -Fx 'TOOL[first][two words]'
"${MOON_BIN}" exec -- tool -- -- | grep -Fx 'TOOL[--][--]'
"${MOON_BIN}" exec -- tool x -- y | grep -Fx 'TOOL[x][--][y]'
"${MOON_BIN}" exec -- tool run x -- --something-else | grep -Fx 'TOOL[run][x][--][--something-else]'

# The same mandatory "--" also escapes a hyphen-leading command name from
# moonstone's own flag parsing.
"${MOON_BIN}" exec -- -strange arg | grep -Fx 'STRANGE[arg]'

echo "━━━ ✓ moon exec delimiter semantics passed ━━━"
