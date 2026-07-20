#!/usr/bin/env bash
set -euo pipefail

source "${PROJECT_ROOT}/tests/scripts/lib/assert.sh"

WORKDIR="/tmp/moonstone-contract-runtime-abi"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"

cd "${WORKDIR}"
moon init luajit-app --name luajit-app --interpreter luajit@2.1.1783773675 --no-sync --no-git
assert_file_contains "${WORKDIR}/luajit-app/moonstone.toml" 'name = "luajit"'
assert_file_contains "${WORKDIR}/luajit-app/moonstone.toml" 'version = "2.1.1783773675"'
assert_file_contains "${WORKDIR}/luajit-app/moonstone.toml" 'abi = "5.1"'

cd "${WORKDIR}/luajit-app"
moon interpreter set love@11.5 --no-sync
assert_file_contains "moonstone.toml" 'name = "love"'
assert_file_contains "moonstone.toml" 'version = "11.5"'
assert_file_contains "moonstone.toml" 'abi = "5.1"'

cat > moonstone.toml <<'TOML'
[package]
name = "native-runtime-app"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4.6"
abi = "5.4"

[dependencies.runtime]
TOML
moon interpreter set lua@5.3 --no-sync
assert_file_contains "moonstone.toml" 'name = "lua"'
assert_file_contains "moonstone.toml" 'version = "5.3"'
assert_file_contains "moonstone.toml" 'abi = "5.3"'

cd "${WORKDIR}"
moon init abi-negative --name abi-negative --interpreter lua@5.4 --no-sync --no-git
cd "${WORKDIR}/abi-negative"
cat >> moonstone.toml <<'TOML'

[resolution]
default_order = ["moonstone"]
TOML
python3 - <<'PY'
from pathlib import Path
path = Path('moonstone.toml')
text = path.read_text()
text = text.replace('abi = "5.4"', 'abi = "5.1"')
path.write_text(text)
PY
moon add inspect@3.1.3 --no-sync >/tmp/moonstone-runtime-abi-negative.out 2>&1
assert_file_contains moonstone.toml 'role = "runtime"'
