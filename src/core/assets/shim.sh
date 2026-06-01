#!/usr/bin/env sh
set -e

# Resolve active version:
# 1) project pin (./.moonstone-version)
# 2) env override (MOONSTONE_VERSION)
# 3) global selection (~/.local/share/moonstone/active OR $MOONSTONE_HOME/active)
resolve_version() {
  if [ -f ".moonstone-version" ]; then
    cat ".moonstone-version"
    return
  fi
  if [ -n "${MOONSTONE_VERSION:-}" ]; then
    printf "%s" "$MOONSTONE_VERSION"
    return
  fi
  if [ -n "${MOONSTONE_HOME:-}" ] && [ -f "$MOONSTONE_HOME/active" ]; then
    cat "$MOONSTONE_HOME/active"
    return
  fi
  printf "moonstone: no active version (set .moonstone-version or MOONSTONE_VERSION or run 'moonstone use')\n" >&2
  exit 1
}

: "${MOONSTONE_HOME:=${XDG_DATA_HOME:-$HOME/.local/share}/moonstone}"
ver="$(resolve_version)"

# Optional: per-version env (comment in if you don’t inject via `activate`)
# export LUA_PATH="$MOONSTONE_HOME/versions/$ver/share/lua/?.lua;$MOONSTONE_HOME/versions/$ver/share/lua/?/init.lua;$LUA_PATH"
# export LUA_CPATH="$MOONSTONE_HOME/versions/$ver/lib/lua/?.so;$LUA_CPATH"

exe_name="$(basename "$0")"
exe_path="$MOONSTONE_HOME/versions/$ver/bin/$exe_name"

if [ ! -x "$exe_path" ]; then
  printf "moonstone: executable not found for %s in %s\n" "$exe_name" "$exe_path" >&2
  exit 127
fi

exec "$exe_path" "$@"

