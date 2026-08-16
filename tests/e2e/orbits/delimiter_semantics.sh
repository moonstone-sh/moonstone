#!/usr/bin/env bash
set -euo pipefail

# Test: orbit execution retains the top-level argument contracts inside a
# declared child project without requiring registry resolution.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"
WORKDIR="$(mktemp -d /tmp/moonstone-orbit-delimiters.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT

mkdir -p "${WORKDIR}/child/.moonstone/env/bin"
cat > "${WORKDIR}/moonstone.toml" <<'TOML'
manifest_version = 2

[package]
name = "orbit-delimiter-root"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[[orbits.member]]
name = "child"
path = "child"
TOML

cat > "${WORKDIR}/child/moonstone.toml" <<'TOML'
manifest_version = 2

[package]
name = "orbit-delimiter-child"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[scripts]
args = 'printf "RUN"; for argument in "$@"; do printf "[%s]" "$argument"; done; printf "\\n"'
TOML

cat > "${WORKDIR}/child/.moonstone/env/env.toml" <<'TOML'
[runtime]
name = "lua"
version = "5.4.7"
abi = "lua54"
TOML

cat > "${WORKDIR}/child/.moonstone/env/bin/tool" <<'SH'
#!/usr/bin/env sh
printf 'EXEC'
for argument in "$@"; do printf '[%s]' "$argument"; done
printf '\n'
SH
chmod +x "${WORKDIR}/child/.moonstone/env/bin/tool"

cd "${WORKDIR}"
"${MOON_BIN}" orbit run child args -- first "two words" | grep -Fx 'RUN[first][two words]'
"${MOON_BIN}" orbit exec child tool -- first "two words" | grep -Fx 'EXEC[first][two words]'
"${MOON_BIN}" orbit exec child tool -- -- | grep -Fx 'EXEC[--]'

echo "━━━ ✓ orbit delimiter semantics passed ━━━"
