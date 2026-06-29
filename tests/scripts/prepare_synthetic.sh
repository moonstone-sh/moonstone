#!/usr/bin/env bash

# This script is intended to be sourced:
#   source ./prepare-synthetic.sh

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "ERROR: this script must be sourced from bash, not zsh/sh."
  return 1 2>/dev/null || exit 1
fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "ERROR: this script must be sourced, not executed."
  echo "Run:"
  echo "  source ${BASH_SOURCE[0]}"
  exit 1
fi

moonstone_prepare_synthetic() {
  local project_root
  local moon_bin

  project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  moon_bin="${project_root}/zig-out/bin/moon"

  if [[ ! -x "${moon_bin}" ]]; then
    echo "ERROR: moon binary not found at ${moon_bin}"
    echo "Run: zig build"
    return 1
  fi

  export PROJECT_ROOT="${project_root}"
  export MOON_BIN="${moon_bin}"
  export SANDBOX_DIR="${project_root}/fixtures/sandbox"

  export MOONSTONE_HOME="/tmp/moonstone-synthetic-home"
  export HOME="${MOONSTONE_HOME}"

  export MOONSTONE_CONFIG="${MOONSTONE_HOME}/config"
  export MOONSTONE_DATA="${MOONSTONE_HOME}/data"
  export MOONSTONE_CACHE="${MOONSTONE_HOME}/cache"

  export MOONSTONE_REGISTRY_PATH="${SANDBOX_DIR}"

  export XDG_CONFIG_HOME="${MOONSTONE_HOME}/xdg-config"
  export XDG_DATA_HOME="${MOONSTONE_HOME}/xdg-data"
  export XDG_CACHE_HOME="${MOONSTONE_HOME}/xdg-cache"

  export PATH="${moon_bin%/*}:${PATH}"

  echo "Cleaning up old synthetic home..."
  rm -rf "${MOONSTONE_HOME}"

  echo "Creating directory structure..."
  mkdir -p "${MOONSTONE_CONFIG}/links"
  mkdir -p "${MOONSTONE_DATA}/store/v0"
  mkdir -p "${MOONSTONE_DATA}/index/v0"
  mkdir -p "${MOONSTONE_DATA}/tmp"
  mkdir -p "${MOONSTONE_CACHE}/downloads"
  mkdir -p "${MOONSTONE_DATA}/v0/shims"
  mkdir -p "${XDG_CONFIG_HOME}"
  mkdir -p "${XDG_DATA_HOME}"
  mkdir -p "${XDG_CACHE_HOME}"

  echo "Writing config.toml..."
  cat >"${MOONSTONE_CONFIG}/config.toml" <<EOF
[moonstone]
default_runtime = "lua@5.4.7"

[paths]
store = "${MOONSTONE_DATA}/store/v0"
index = "${MOONSTONE_DATA}/index/v0"
cache = "${MOONSTONE_CACHE}"
downloads = "${MOONSTONE_CACHE}/downloads"
shims = "${MOONSTONE_DATA}/v0/shims"

[registries.synthetic]
path = "${SANDBOX_DIR}/registry"
priority = 100

EOF

  echo "Preparation complete."
  echo "MOONSTONE_HOME=${MOONSTONE_HOME}"
}

moonstone_prepare_synthetic
unset -f moonstone_prepare_synthetic

