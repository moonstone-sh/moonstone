#!/usr/bin/env bash
set -euo pipefail

# Test: Reproducibility (--locked)
# - Verifies success on valid lockfile
# - Verifies failure on missing entry or hash mismatch

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="/tmp/moonstone-reproducibility"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# Reset and create a fresh project
cat > moonstone.toml <<EOF
[package]
name = "repro-test"
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
EOF

moon interpreter set lua@5.4 --no-sync

echo "━━━ add dependency ━━━"
moon add synthetic:inspect@3.1.3 --no-sync

echo "━━━ initial install ━━━"
moon sync

echo "━━━ locked install (success) ━━━"
moon sync --locked

echo "━━━ locked install (offline cache replay) ━━━"
moon sync --locked --offline

echo "━━━ locked install (missing entry error) ━━━"
# Add a dependency that is NOT in the lockfile, using [[dependencies]] format
printf '\n[[dependencies]]\nname = "luassert"\nconstraint = "^1.9.0"\nregistry = "synthetic"\nrole = "runtime"\n' >> moonstone.toml
! moon sync --locked

echo "━━━ sync lockfile ━━━"
# Remove the extra dep and re-sync
python3 -c "
from pathlib import Path
p = Path('moonstone.toml')
text = p.read_text()
# Remove the luassert [[dependencies]] block
idx = text.find('\n[[dependencies]]\nname = \"luassert\"')
if idx >= 0:
    p.write_text(text[:idx])
"
moon sync

echo "━━━ locked install (hash mismatch error) ━━━"
# Corrupt the artifact hash in the lockfile
python3 -c "
from pathlib import Path
p = Path('moonstone.lock')
text = p.read_text()
text = text.replace('artifact_hash = \"b3:', 'artifact_hash = \"b3:corrupted', 1)
p.write_text(text)
"
! moon sync --locked

echo "━━━ ✓ Reproducibility test passed ━━━"
