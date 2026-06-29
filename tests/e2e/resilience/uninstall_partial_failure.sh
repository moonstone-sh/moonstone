#!/usr/bin/env bash
set -euo pipefail

MOON_BIN="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/zig-out/bin/moon"

WORKDIR="$(mktemp -d /tmp/moonstone-uninstall-partial.XXXXXX)"
trap 'chflags -R nouchg "$WORKDIR" 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/data/tmp/locked" "$WORKDIR/config" "$WORKDIR/cache" "$WORKDIR/shims" "$WORKDIR/projects"
touch "$WORKDIR/data/tmp/locked/file"
chflags uchg "$WORKDIR/data/tmp/locked/file"
if MOONSTONE_HOME="$WORKDIR" MOONSTONE_DATA="$WORKDIR/data" MOONSTONE_CONFIG="$WORKDIR/config" MOONSTONE_CACHE="$WORKDIR/cache" XDG_DATA_HOME="$WORKDIR/xdg-data" XDG_CONFIG_HOME="$WORKDIR/xdg-config" XDG_CACHE_HOME="$WORKDIR/xdg-cache" "$MOON_BIN" uninstall --force >"$WORKDIR/stdout" 2>"$WORKDIR/stderr"; then
  echo "expected moon uninstall to fail when a path cannot be removed" >&2
  exit 1
fi
grep 'warning: could not remove' "$WORKDIR/stderr"
grep 'Moonstone partially uninstalled' "$WORKDIR/stdout"
