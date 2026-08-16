#!/usr/bin/env bash
set -euo pipefail

# Contract: a runtime native_lib provision is linked into the project
# environment and a public binary can resolve its shared-library dependency
# through Moonstone's host loader projection.

if [[ "$(uname -s)" == "MINGW"* || "$(uname -s)" == "MSYS"* || "$(uname -s)" == "CYGWIN"* ]]; then
    echo "━━━ native library projection probe is covered by the Windows job ━━━"
    exit 0
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="$(mktemp -d /tmp/moonstone-native-library-projection.XXXXXX)"
REGISTRY="${WORKDIR}/registry"
PAYLOAD="${WORKDIR}/payload"
APP="${WORKDIR}/app"
PACKAGE="native-loader-probe"
VERSION="0.1.0"

cleanup() {
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

blake3_file() {
    zig run "${PROJECT_ROOT}/tests/helpers/blake3_file.zig" -- "$1"
}

cp -R "${SANDBOX_DIR}/registry" "${REGISTRY}"
rm -f "${REGISTRY}/index.sqlite.zst"
sed -i.bak '/^\[index\.compact\]/,/^$/d' "${REGISTRY}/registry.toml"
rm -f "${REGISTRY}/registry.toml.bak"
mkdir -p "${PAYLOAD}/bin" "${PAYLOAD}/lib" "${WORKDIR}/src" "${APP}"

cat > "${WORKDIR}/src/native_probe.c" <<'EOF'
const char *native_probe_message(void) {
    return "native loader projected";
}
EOF
cat > "${WORKDIR}/src/main.c" <<'EOF'
#include <stdio.h>
const char *native_probe_message(void);
int main(void) {
    puts(native_probe_message());
    return 0;
}
EOF

case "$(uname -s)" in
    Darwin)
        LIB_NAME="libnativeprobe.dylib"
        zig cc -dynamiclib "${WORKDIR}/src/native_probe.c" -Wl,-install_name,"${LIB_NAME}" -o "${PAYLOAD}/lib/${LIB_NAME}"
        zig cc "${WORKDIR}/src/main.c" -L"${PAYLOAD}/lib" -lnativeprobe -o "${PAYLOAD}/bin/${PACKAGE}"
        ;;
    Linux|FreeBSD)
        LIB_NAME="libnativeprobe.so"
        zig cc -shared "${WORKDIR}/src/native_probe.c" -o "${PAYLOAD}/lib/${LIB_NAME}"
        zig cc "${WORKDIR}/src/main.c" -L"${PAYLOAD}/lib" -lnativeprobe -o "${PAYLOAD}/bin/${PACKAGE}"
        ;;
    *)
        echo "SKIP: unsupported native loader test host $(uname -s)"
        exit 0
        ;;
esac
printf 'static archive fixture\n' > "${PAYLOAD}/lib/libstaticprobe.a"

TARBALL="${WORKDIR}/${PACKAGE}.tar.gz"
tar -czf "${TARBALL}" -C "${PAYLOAD}" bin lib
HASH="$(blake3_file "${TARBALL}")"
BYTES="$(stat -f%z "${TARBALL}" 2>/dev/null || stat -c%s "${TARBALL}")"
SHARD="${REGISTRY}/blobs/b3/${HASH:0:2}/${HASH:2:2}"
mkdir -p "${SHARD}" "${REGISTRY}/packages/${PACKAGE}/${VERSION}"
cp "${TARBALL}" "${SHARD}/${HASH}.tar.gz"

DESCRIPTOR="${REGISTRY}/packages/${PACKAGE}/${VERSION}/package.toml"
cat > "${DESCRIPTOR}" <<EOF
[package]
name = "${PACKAGE}"
version = "${VERSION}"
kind = "bin"
description = "Native loader projection probe"

[[artifacts]]
id = "native-loader-host"
kind = "bin"
target = "any"
lua_api = "5.4"
lua_abi = "lua-5.4"
runtime = "lua@5.4.7"
format = "tar.gz"
url = "blobs/b3/${HASH:0:2}/${HASH:2:2}/${HASH}.tar.gz"
hash = "b3:${HASH}"
recipe_hash = "b3:0000000000000000000000000000000000000000000000000000000000000000"
bytes = ${BYTES}

[artifacts.materialize]
type = "archive"
strip_components = 0

[[artifacts.provides]]
kind = "bin"
name = "${PACKAGE}"
path = "bin/${PACKAGE}"

[[artifacts.provides]]
kind = "lib"
name = "native-probe"
path = "lib/${LIB_NAME}"
linkage = "shared"

[[artifacts.provides]]
kind = "lib"
name = "static-probe"
path = "lib/libstaticprobe.a"
linkage = "static"
EOF
DESCRIPTOR_HASH="$(blake3_file "${DESCRIPTOR}")"
cat >> "${REGISTRY}/index.toml" <<EOF

[[package]]
name = "${PACKAGE}"
version = "${VERSION}"
kind = "bin"
descriptor = "packages/${PACKAGE}/${VERSION}/package.toml"
descriptor_hash = "b3:${DESCRIPTOR_HASH}"
targets = ["any"]
runtimes = ["lua@5.4.7"]
EOF

INDEX_HASH="$(blake3_file "${REGISTRY}/index.toml")"
INDEX_BYTES="$(stat -f%z "${REGISTRY}/index.toml" 2>/dev/null || stat -c%s "${REGISTRY}/index.toml")"
perl -0pi -e "s/hash = \"b3:[a-f0-9]+\"/hash = \"b3:${INDEX_HASH}\"/; s/bytes = [0-9]+/bytes = ${INDEX_BYTES}/" "${REGISTRY}/registry.toml"

cd "${APP}"
moon init . --name native-library-projection --no-git --no-sync
moon interpreter set lua@5.4 --no-sync
moon registry add native-loader "${REGISTRY}" --default
moon add "native-loader:${PACKAGE}"

if [[ ! -L ".moonstone/env/lib/native/${LIB_NAME}" ]]; then
    echo "ERROR: native library was not linked into the project environment" >&2
    find .moonstone/env -maxdepth 4 -print >&2
    exit 1
fi
if [[ -e ".moonstone/env/lib/native/libstaticprobe.a" ]]; then
    echo "ERROR: static native library must not enter the loader projection" >&2
    exit 1
fi

moon env --json | grep -Fq '"native_lib_path":"'
moon exec "${PACKAGE}" | grep -q 'native loader projected'

echo "━━━ ✓ native-library projection and loader contract passed ━━━"
