#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_TAG="${MOONSTONE_LINUX_CI_IMAGE:-moonstone-ci-linux:local}"
if [[ -n "${MOONSTONE_LINUX_CI_PLATFORM:-}" ]]; then
    PLATFORM="${MOONSTONE_LINUX_CI_PLATFORM}"
else
    case "$(uname -m)" in
        arm64|aarch64) PLATFORM="linux/arm64" ;;
        *) PLATFORM="linux/amd64" ;;
    esac
fi

if [[ "${PLATFORM}" == "linux/amd64" ]] && [[ "$(uname -s)" == "Darwin" ]] && [[ "$(uname -m)" == "arm64" ]]; then
    cat >&2 <<'WARNING'
warning: running linux/amd64 through Docker emulation on Apple Silicon

This is a best-effort local check. Some Zig workloads can fail in Rosetta with
"bss_size overflow" before Moonstone runs. The host-native linux/arm64 mode is
the supported local contract; GitHub's native Ubuntu job remains authoritative
for linux/amd64 validation.
WARNING
fi

usage() {
    cat <<'USAGE'
Usage: scripts/ci/run-linux.sh [luv|native-rocks|all]

Builds Moonstone's local Linux CI image and runs the requested scope. The
container defaults to the host-native Linux architecture for reliable local
execution. Set MOONSTONE_LINUX_CI_PLATFORM=linux/amd64 to match GitHub's
Ubuntu runner ABI explicitly when Docker's x86_64 emulation is reliable.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

scope="${1:-all}"
case "${scope}" in
    luv|native-rocks|all) ;;
    *)
        usage >&2
        exit 64
        ;;
esac

cd "${ROOT_DIR}"
docker build --platform "${PLATFORM}" -f tests/Dockerfile.ci-linux -t "${IMAGE_TAG}" .
# The image intentionally excludes generated sandbox state from its build
# context. Release certification regenerates that mutable fixture tree inside
# the disposable container, so never bind the developer's sandbox into it.
docker run --rm --platform "${PLATFORM}" \
    "${IMAGE_TAG}" "${scope}"
