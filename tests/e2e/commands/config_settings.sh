#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="$(mktemp -d /tmp/moonstone-config-settings.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT

cat > "${WORKDIR}/config.toml" <<'TOML'
[registries]
internal = { url = "https://packages.example.invalid", priority = 5 }
TOML

moon --config-file "${WORKDIR}/config.toml" config get network.timeout | grep -Fx 'network.timeout = 30 (default)'
moon --config-file "${WORKDIR}/config.toml" config get network.timeout --default | grep -Fx 'network.timeout = 30 (default)'
moon --config-file "${WORKDIR}/config.toml" config get network.timeout --json | grep -Fq '"kind":"RESULT"'
moon --config-file "${WORKDIR}/config.toml" config set network.timeout 12 --json | grep -Fq '"kind":"RESULT"'
moon --config-file "${WORKDIR}/config.toml" config get network.timeout | grep -Fx 'network.timeout = 12 (config)'
moon --config-file "${WORKDIR}/config.toml" config set cli.verbose true --json | grep -Fq '"kind":"RESULT"'
moon --config-file "${WORKDIR}/config.toml" config unset network.timeout --json | grep -Fq '"kind":"RESULT"'
moon --config-file "${WORKDIR}/config.toml" config get network.timeout | grep -Fx 'network.timeout = 30 (default)'
moon --config-file "${WORKDIR}/config.toml" completions --complete 'moon config set net' | grep -qx 'network.timeout'
moon --config-file "${WORKDIR}/config.toml" completions --complete 'moon config unset cli.' | grep -qx 'cli.verbose'
grep -Fq 'internal = { url = "https://packages.example.invalid", priority = 5 }' "${WORKDIR}/config.toml"
grep -Fq 'verbose = true' "${WORKDIR}/config.toml"

if moon --config-file "${WORKDIR}/config.toml" config set network.timeout invalid >/dev/null 2>&1; then
    echo "config accepted an invalid integer" >&2
    exit 1
fi

if moon --config-file "${WORKDIR}/config.toml" config set unknown.setting true >/dev/null 2>&1; then
    echo "config accepted an unknown setting" >&2
    exit 1
fi

chmod 0444 "${WORKDIR}/config.toml"
if moon --config-file "${WORKDIR}/config.toml" config set cli.color false >"${WORKDIR}/readonly.log" 2>&1; then
    echo "config modified a read-only file" >&2
    exit 1
fi
grep -Fq 'active Moonstone config file is read-only or cannot be modified' "${WORKDIR}/readonly.log"
chmod 0644 "${WORKDIR}/config.toml"

echo "━━━ ✓ Typed config settings passed ━━━"
