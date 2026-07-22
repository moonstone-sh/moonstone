#!/usr/bin/env bash
set -euo pipefail

echo "==> Materializing local artifacts..."
moon sync

echo "==> Packaging & publishing verified CAS artifacts to registry..."
moon store publish --target aarch64-macos --registry https://registry.moonstone.sh

echo "==> Verifying idempotent re-publication..."
moon store publish --target aarch64-macos --registry https://registry.moonstone.sh
