#!/usr/bin/env bash
set -euo pipefail

# Test: an explicit Moonstone registry dependency must not resolve through a
# same-name live link registered for local development.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="$(mktemp -d /tmp/moonstone-explicit-registry-link.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT
mkdir -p "${WORKDIR}/linked-inspect/src" "${WORKDIR}/app"

cat > "${WORKDIR}/linked-inspect/moonstone.toml" <<'TOML'
[package]
name = "inspect"
version = "3.1.3"
kind = "lib"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies.runtime]
TOML

cat > "${WORKDIR}/linked-inspect/src/inspect.lua" <<'LUA'
return function()
  return "live-link-won"
end
LUA

(cd "${WORKDIR}/linked-inspect" && moon link)

cd "${WORKDIR}/app"
moon init . --name explicit-registry-link-app --no-git --no-sync
moon interpreter set lua@5.4 --no-sync
moon registry add local-synthetic "${SANDBOX_DIR}/registry" --default
moon add moonstone:inspect@3.1.3

grep -q '^resolver = "moonstone"$' moonstone.lock
if grep -q '^artifact_hash = "link"$' moonstone.lock; then
    echo "ERROR: explicit Moonstone dependency resolved through a live link"
    exit 1
fi

moon exec -- lua -e 'local inspect = require("inspect"); print(inspect({ source = "registry" }))' | grep -q 'registry'
if moon exec -- lua -e 'local inspect = require("inspect"); print(inspect())' | grep -q 'live-link-won'; then
    echo "ERROR: live link shadowed explicit Moonstone registry dependency"
    exit 1
fi

echo "━━━ ✓ Explicit Moonstone resolver bypasses same-name live link ━━━"
