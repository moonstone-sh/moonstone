#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JOB="${1:-test}"
EVENT="${MOONSTONE_ACT_EVENT:-push}"
IMAGE="${MOONSTONE_ACT_IMAGE:-ghcr.io/catthehacker/ubuntu:act-24.04-20260601}"

usage() {
    cat <<'USAGE'
Usage: scripts/ci/run-github-actions.sh [test|release-candidate]

Runs Moonstone's checked-in GitHub Actions workflow locally through nektos/act.
The Linux runner image is pinned so the workflow, action graph, and Ubuntu
baseline are exercised together instead of through a separate approximation.

Environment:
  MOONSTONE_ACT_ARCH   Docker platform (default: host-native linux/arm64 or linux/amd64)
  MOONSTONE_ACT_IMAGE  Override the pinned Ubuntu runner image
  MOONSTONE_ACT_EVENT  GitHub Actions event (default: push)
  MOONSTONE_ACT_WORKDIR  Keep the staged workspace at this path for debugging

Examples:
  scripts/ci/run-github-actions.sh test
  MOONSTONE_ACT_ARCH=linux/amd64 scripts/ci/run-github-actions.sh test
USAGE
}

case "${JOB}" in
    test|release-candidate) ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac

if ! command -v act >/dev/null 2>&1; then
    cat >&2 <<'ERROR'
error: nektos/act is required to reproduce GitHub Actions locally

Install it with your package manager, for example:
  brew install act
ERROR
    exit 127
fi

if ! docker info >/dev/null 2>&1; then
    echo "error: Docker must be running before invoking act" >&2
    exit 1
fi

if ! command -v rsync >/dev/null 2>&1; then
    echo "error: rsync is required to stage an isolated Act workspace" >&2
    exit 127
fi

if [[ -n "${MOONSTONE_ACT_ARCH:-}" ]]; then
    ARCH="${MOONSTONE_ACT_ARCH}"
else
    case "$(uname -m)" in
        arm64|aarch64) ARCH="linux/arm64" ;;
        *) ARCH="linux/amd64" ;;
    esac
fi

if [[ "${ARCH}" == "linux/amd64" ]] && [[ "$(uname -s)" == "Darwin" ]] && [[ "$(uname -m)" == "arm64" ]]; then
    cat >&2 <<'WARNING'
warning: running GitHub's linux/amd64 shape through Docker emulation on Apple Silicon

This is useful as an additional compatibility signal, but Zig workloads can
fail inside Rosetta before Moonstone executes. The host-native Linux Act run is
the supported local workflow check; GitHub's Ubuntu runner remains authoritative
for the exact amd64 gate.
WARNING
fi

if [[ -n "${MOONSTONE_ACT_WORKDIR:-}" ]]; then
    WORK_DIR="${MOONSTONE_ACT_WORKDIR}"
    mkdir -p "${WORK_DIR}"
    CLEANUP_WORK_DIR=false
else
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/moonstone-act.XXXXXX")"
    CLEANUP_WORK_DIR=true
fi

cleanup() {
    if [[ "${CLEANUP_WORK_DIR}" == true ]]; then
        rm -rf "${WORK_DIR}"
    fi
}
trap cleanup EXIT

# Act otherwise stages the checkout at the same absolute host path, allowing a
# Linux workflow to overwrite local zig-out or cache artifacts. Copy the full
# working tree (including uncommitted edits and Git metadata) into a disposable
# workspace, but exclude generated state that CI creates for itself.
rsync -a --delete \
    --exclude '.ci/' \
    --exclude '.moonstone/' \
    --exclude '.zig-cache/' \
    --exclude '.zig-global-cache/' \
    --exclude 'zig-cache/' \
    --exclude 'zig-out/' \
    --exclude 'dist/' \
    --exclude 'fixtures/sandbox/' \
    --exclude 'node_modules/' \
    "${ROOT_DIR}/" "${WORK_DIR}/"

cd "${WORK_DIR}"
act "${EVENT}" \
    --workflows .github/workflows/ci.yml \
    --job "${JOB}" \
    --platform "ubuntu-latest=${IMAGE}" \
    --container-architecture "${ARCH}" \
    --container-daemon-socket - \
    --env CI=true
