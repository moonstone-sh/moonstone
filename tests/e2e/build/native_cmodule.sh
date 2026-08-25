#!/usr/bin/env bash
set -euo pipefail

# Test: Native C module materialization
# - Adds synthetic-cmodule
# - Builds and verifies it works via moon exec

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "$(dirname "$0")/../../scripts/install_synthetic.sh"
fi

cd "${SANDBOX_DIR}/my-app"

# Reset my-app
rm -rf .moonstone
rm -f moonstone.lock
cat > moonstone.toml << EOF
[package]
name = "my-app"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[[registries]]
name = "synthetic"
resolver = "moonstone"
path = "${SANDBOX_DIR}/registry"
priority = 10

[dependencies.runtime]
EOF

moon interpreter set lua@5.4

echo "━━━ report missing native materialization input during add ━━━"
MISSING_ADD_LOG="${SANDBOX_DIR}/native-cmodule-missing-add.log"
if env -u SYNTHETIC_SDK_INCDIR moon add synthetic:synthetic-cmodule >"${MISSING_ADD_LOG}" 2>&1; then
    echo "ERROR: native package unexpectedly added without its declared external path"
    exit 1
fi
grep -Fq 'Package synthetic-cmodule@0.1.0 requires external development files.' "${MISSING_ADD_LOG}"
grep -Fq 'SYNTHETIC_SDK_INCDIR — include directory (headers)' "${MISSING_ADD_LOG}"

SYNTHETIC_SDK_DIR="${SANDBOX_DIR}/synthetic-sdk/include"
mkdir -p "${SYNTHETIC_SDK_DIR}"
export SYNTHETIC_SDK_INCDIR="${SYNTHETIC_SDK_DIR}"
moon add synthetic:synthetic-cmodule

# Force the locked package through source materialization again so validation
# is exercised by `moon sync`, the normal repair/replay boundary.
moon store purge --force

echo "━━━ report missing native materialization input ━━━"
MISSING_PATHS_LOG="${SANDBOX_DIR}/native-cmodule-missing-paths.log"
if env -u SYNTHETIC_SDK_INCDIR moon sync --update >"${MISSING_PATHS_LOG}" 2>&1; then
    echo "ERROR: native package unexpectedly materialized without its declared external path"
    exit 1
fi
grep -Fq 'Package synthetic-cmodule@0.1.0 requires external development files.' "${MISSING_PATHS_LOG}"
grep -Fq 'SYNTHETIC_SDK_INCDIR — include directory (headers)' "${MISSING_PATHS_LOG}"

MISSING_PATHS_JSON_LOG="${SANDBOX_DIR}/native-cmodule-missing-paths.ndjson"
if env -u SYNTHETIC_SDK_INCDIR moon sync --update --json >"${MISSING_PATHS_JSON_LOG}" 2>&1; then
    echo "ERROR: JSON sync unexpectedly materialized the native package without its declared external path"
    exit 1
fi
grep -Eq '"kind"[[:space:]]*:[[:space:]]*"external_dependency_paths"' "${MISSING_PATHS_JSON_LOG}"
grep -Eq '"package"[[:space:]]*:[[:space:]]*"synthetic-cmodule"' "${MISSING_PATHS_JSON_LOG}"
grep -Eq '"variable"[[:space:]]*:[[:space:]]*"SYNTHETIC_SDK_INCDIR"' "${MISSING_PATHS_JSON_LOG}"

moon sync --update

echo "━━━ check cmodule symlink ━━━"
find .moonstone/env/lib/lua -type l -name 'synthetic_cmodule.*' | grep -q .

echo "━━━ run cmodule test ━━━"
moon exec -- lua -e 'local m = require("synthetic_cmodule"); print(m.hello())' | grep "hello from synthetic cmodule"

echo "━━━ ✓ native C module materialization passed ━━━"
