#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE="moonstone-wine-test"

usage() {
    cat <<'USAGE'
Usage: scripts/test-windows-wine.sh [core]

Builds Moonstone's x86_64 Windows executable and runs the selected Windows
contract under Wine.  The Linux/amd64 container is intentional: it lets an
Apple Silicon Docker host emulate the x86_64 Wine runtime required by moon.exe.
USAGE
}

suite="${1:-core}"
case "${suite}" in
    core) ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac

echo "=== Building Moonstone Windows (Wine) Test Container ==="
docker build \
    --platform linux/amd64 \
    -f "${ROOT_DIR}/tests/docker/Dockerfile.wine" \
    -t "${IMAGE}" \
    "${ROOT_DIR}"

echo
echo "=== Running Windows ${suite} contract under Wine inside Docker ==="
docker run --platform linux/amd64 --rm "${IMAGE}" "${suite}"
