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
docker run --rm --platform "${PLATFORM}" "${IMAGE_TAG}" "${scope}"
