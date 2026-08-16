#!/usr/bin/env bash
set -euo pipefail

# Test: moon exec keeps child arguments opaque while consuming one optional
# post-command delimiter.

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

cd "${WORKDIR}"
"${MOON_BIN}" exec tool direct | grep -Fx 'TOOL[direct]'
"${MOON_BIN}" exec tool -- first "two words" | grep -Fx 'TOOL[first][two words]'
"${MOON_BIN}" exec tool -- -- | grep -Fx 'TOOL[--]'

echo "━━━ ✓ moon exec delimiter semantics passed ━━━"
