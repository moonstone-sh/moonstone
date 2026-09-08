#!/usr/bin/env bash
set -euo pipefail

# Contract: a `path:` dependency may declare its own native libraries in its
# moonstone.toml, and Moonstone projects them into the consumer's
# .moonstone/env/lib/native exactly as it already does for artifact-backed
# native_lib provisions — including the host loader environment.
#
# This is the path-dependency equivalent of
# tests/e2e/commands/native_library_projection.sh: a real shared library, a
# real executable that can only resolve it through Moonstone's projected loader
# environment, and a real `moon exec`.

if [[ "$(uname -s)" == "MINGW"* || "$(uname -s)" == "MSYS"* || "$(uname -s)" == "CYGWIN"* ]]; then
    echo "━━━ path-dependency native library projection is covered by the Windows job ━━━"
    exit 0
fi

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"

WORKDIR="$(mktemp -d /tmp/moonstone-path-native-library.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT

DEP="${WORKDIR}/probe"
APP="${WORKDIR}/app"
mkdir -p "${DEP}/native/dist" "${DEP}/bin" "${DEP}/src" "${APP}"

cat > "${DEP}/native/path_probe.c" <<'EOF'
const char *path_probe_message(void) {
    return "path dependency native library projected";
}
EOF
cat > "${DEP}/native/main.c" <<'EOF'
#include <stdio.h>
const char *path_probe_message(void);
int main(void) {
    puts(path_probe_message());
    return 0;
}
EOF

case "$(uname -s)" in
    Darwin)
        LIB_NAME="libpathprobe.dylib"
        zig cc -dynamiclib "${DEP}/native/path_probe.c" \
            -Wl,-install_name,"${LIB_NAME}" -o "${DEP}/native/dist/${LIB_NAME}"
        ;;
    Linux|FreeBSD)
        LIB_NAME="libpathprobe.so"
        zig cc -shared "${DEP}/native/path_probe.c" -o "${DEP}/native/dist/${LIB_NAME}"
        ;;
    *)
        echo "SKIP: unsupported native loader test host $(uname -s)"
        exit 0
        ;;
esac
zig cc "${DEP}/native/main.c" -L"${DEP}/native/dist" -lpathprobe -o "${DEP}/bin/path-native-probe"
printf 'static archive fixture\n' > "${DEP}/native/dist/libpathprobe.a"

cat > "${DEP}/moonstone.toml" <<TOML
[package]
name = "path-native-probe"
version = "0.1.0"
kind = "bin"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[[provides.native_lib]]
name = "pathprobe"
path = "native/dist/${LIB_NAME}"

[[provides.native_lib]]
name = "pathprobe-archive"
path = "native/dist/libpathprobe.a"
linkage = "static"
TOML

(
    cd "${APP}"
    "${MOON_BIN}" init . --name path-native-app --kind script --interpreter lua@5.4 --no-git --no-sync
    "${MOON_BIN}" add path:../probe
)

cd "${APP}"

if [[ ! -L ".moonstone/env/lib/native/${LIB_NAME}" ]]; then
    echo "ERROR: declared native library was not linked into the project environment" >&2
    find .moonstone/env -maxdepth 4 -print >&2
    exit 1
fi

# -ef compares device and inode through the symlink: the projected entry must
# be the dependency's own file, not a copy of it.
if [[ ! ".moonstone/env/lib/native/${LIB_NAME}" -ef "${DEP}/native/dist/${LIB_NAME}" ]]; then
    echo "ERROR: projection does not resolve to the dependency's own library" >&2
    echo "  link target: $(readlink ".moonstone/env/lib/native/${LIB_NAME}")" >&2
    exit 1
fi

if [[ -e ".moonstone/env/lib/native/libpathprobe.a" ]]; then
    echo "ERROR: a static declaration must not enter the loader projection" >&2
    exit 1
fi

"${MOON_BIN}" env --json | grep -Fq '"native_lib_path":"'

# The executable was linked without an rpath, so it can only find the library
# through Moonstone's projected loader environment.
"${MOON_BIN}" exec path-native-probe | grep -q 'path dependency native library projected'

# A declared-but-unbuilt library must fail loudly instead of syncing a broken
# environment.
mv "${DEP}/native/dist/${LIB_NAME}" "${DEP}/native/dist/${LIB_NAME}.moved"
if "${MOON_BIN}" sync > "${WORKDIR}/missing.log" 2>&1; then
    echo "ERROR: sync succeeded with a missing declared native library" >&2
    cat "${WORKDIR}/missing.log" >&2
    exit 1
fi
grep -q 'does not exist' "${WORKDIR}/missing.log"
mv "${DEP}/native/dist/${LIB_NAME}.moved" "${DEP}/native/dist/${LIB_NAME}"

echo "━━━ ✓ path-dependency native library projection contract passed ━━━"
