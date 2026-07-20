#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-0.3.24}"
ARCH="${2:-amd64}"
WORK_DIR=$(mktemp -d)

trap 'rm -rf "$WORK_DIR"' EXIT

echo "Building Moonstone .deb package for $VERSION ($ARCH)..."

# 1. Compile binary with APT distribution channel
zig build -Doptimize=ReleaseSafe -Ddistribution-channel=apt

# 2. Prepare staging directory
PKG_ROOT="$WORK_DIR/moonstone_${VERSION}_${ARCH}"
mkdir -p "$PKG_ROOT/usr/bin"
mkdir -p "$PKG_ROOT/DEBIAN"

cp zig-out/bin/moon "$PKG_ROOT/usr/bin/moon"
chmod 755 "$PKG_ROOT/usr/bin/moon"

cat <<EOF > "$PKG_ROOT/DEBIAN/control"
Package: moonstone
Version: $VERSION
Architecture: $ARCH
Maintainer: Moonstone Team <dev@moonstone.sh>
Section: utils
Priority: optional
Homepage: https://moonstone.sh
Description: Deterministic Lua runtime and environment manager
 Moonstone is a modern Lua runtime and environment manager written in Zig.
 It manages Lua versions, rocks, and project environments deterministically.
EOF

# 3. Build deb archive
dpkg-deb --build "$PKG_ROOT" "moonstone_${VERSION}_${ARCH}.deb"
echo "Successfully created moonstone_${VERSION}_${ARCH}.deb"
