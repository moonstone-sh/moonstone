#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="$(mktemp -d /tmp/moonstone-local-source-unavailable.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT

write_project() {
    local path="$1"
    local name="$2"
    mkdir -p "${path}/src"
    cat > "${path}/moonstone.toml" <<TOML
[package]
name = "${name}"
version = "0.1.0"
kind = "lib"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"
TOML
    cat > "${path}/src/${name}.lua" <<'LUA'
return true
LUA
}

write_project "${WORKDIR}/path-lib" "path-lib"
mkdir -p "${WORKDIR}/path-app"
cd "${WORKDIR}/path-app"
moon init . --name path-app --no-git --no-sync
moon interpreter set lua@5.4 --no-sync
moon add path:../path-lib --no-sync
moon sync
rm -rf "${WORKDIR}/path-lib"

if moon sync >/tmp/moonstone-missing-path-source.log 2>&1; then
    echo "ERROR: sync succeeded after the path dependency was removed"
    exit 1
fi
grep -q "Locked local path dependency path-lib@0.1.0 is unavailable" /tmp/moonstone-missing-path-source.log
grep -q "moon sync --update" /tmp/moonstone-missing-path-source.log

write_project "${WORKDIR}/link-lib" "link-lib"
(cd "${WORKDIR}/link-lib" && moon link)
mkdir -p "${WORKDIR}/link-app"
cd "${WORKDIR}/link-app"
moon init . --name link-app --no-git --no-sync
moon interpreter set lua@5.4 --no-sync
moon add link:link-lib --no-sync
moon sync
rm -rf "${WORKDIR}/link-lib"

if moon sync --json >/tmp/moonstone-missing-link-source.json 2>&1; then
    echo "ERROR: sync succeeded after the live link target was removed"
    exit 1
fi
grep -q 'LocalSourceUnavailable' /tmp/moonstone-missing-link-source.json
grep -q 'Locked local link dependency link-lib@0.1.0 is unavailable' /tmp/moonstone-missing-link-source.json
grep -q "moon sync --update" /tmp/moonstone-missing-link-source.json

echo "━━━ ✓ Missing local path and link sources report recovery diagnostics ━━━"
