#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_TAG="${MOONSTONE_LINUX_CI_IMAGE:-moonstone-ci-linux:local}"
PLATFORM="${MOONSTONE_LINUX_CI_PLATFORM:-linux/amd64}"

usage() {
    cat <<'USAGE'
Usage: scripts/ci/run-linux.sh [luv|native-rocks|all]

Builds Moonstone's local Linux CI image and runs the requested scope. The
container defaults to linux/amd64 to match GitHub's Ubuntu runner ABI. Set
MOONSTONE_LINUX_CI_PLATFORM=linux/arm64 for a faster Apple Silicon diagnostic
run when exact GitHub architecture parity is not required.
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
