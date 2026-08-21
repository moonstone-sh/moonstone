#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
moon_bin="${MOON_BIN:-moon}"
jobs="${MOONSTONE_DEMO_JOBS:-8}"
progress="${MOONSTONE_DEMO_PROGRESS:-fancy}"
demo_home="${MOONSTONE_DEMO_HOME:-$(mktemp -d "${TMPDIR:-/tmp}/moonstone-rocks-demo.XXXXXX")}"

cleanup() {
    if [[ -z "${MOONSTONE_DEMO_HOME:-}" ]]; then
        rm -rf "${demo_home}"
    fi
}
trap cleanup EXIT

cd "${project_root}"
rm -rf .moonstone moonstone.lock

export MOONSTONE_HOME="${demo_home}/home"
export MOONSTONE_CONFIG="${demo_home}/config"
export MOONSTONE_DATA="${demo_home}/data"
export MOONSTONE_CACHE="${demo_home}/cache"
export HOME="${demo_home}/user-home"
export XDG_CONFIG_HOME="${demo_home}/xdg-config"
export XDG_DATA_HOME="${demo_home}/xdg-data"
export XDG_CACHE_HOME="${demo_home}/xdg-cache"

echo "Cold Moonstone home: ${MOONSTONE_HOME}"
echo "Concurrent workers: ${jobs}"
"${moon_bin}" sync --jobs "${jobs}" --progress "${progress}"
"${moon_bin}" run verify -- --json
