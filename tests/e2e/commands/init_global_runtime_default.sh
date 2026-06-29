#!/usr/bin/env bash
set -euo pipefail

MOON_BIN="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/zig-out/bin/moon"

WORKDIR="$(mktemp -d /tmp/moonstone-init-runtime-default.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/config" "$WORKDIR/data" "$WORKDIR/cache" "$WORKDIR/project"
cat > "$WORKDIR/config/config.toml" <<'TOML'
[moonstone]
default_runtime = "lua-5.5.0"
TOML
HOME="$WORKDIR" MOONSTONE_HOME="$WORKDIR" MOONSTONE_DATA="$WORKDIR/data" MOONSTONE_CONFIG="$WORKDIR/config" MOONSTONE_CACHE="$WORKDIR/cache" XDG_DATA_HOME="$WORKDIR/data" XDG_CONFIG_HOME="$WORKDIR/config" XDG_CACHE_HOME="$WORKDIR/cache" "$MOON_BIN" init "$WORKDIR/project" --name runtime-default --no-git --no-sync
grep 'version = "5.5.0"' "$WORKDIR/project/moonstone.toml"
grep 'abi = "5.5"' "$WORKDIR/project/moonstone.toml"
grep '.moonstone/env/share/lua/5.5' "$WORKDIR/project/.luarc.json"
