#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat <<'USAGE'
Usage: tests/run-platform.sh windows

Runs native platform-only verification. Windows execution requires a Windows
host and PowerShell; Linux and macOS compile-time coverage remains in
`zig build -Dtarget=<triple>`. Add a new platform command only with a real
native contract rather than a host-specific developer fixture.
USAGE
}

platform="${1:-}"
case "${platform}" in
    windows)
        if [[ "${OS:-}" != "Windows_NT" ]]; then
            echo "SKIP: Windows native tests require a Windows host." >&2
            echo "Run in CI or on Windows: pwsh -File tests/windows/core.ps1" >&2
            exit 0
        fi
        exec pwsh -File "${ROOT_DIR}/tests/windows/core.ps1"
        ;;
    -h|--help|"")
        usage
        [[ -n "${platform}" ]] || exit 64
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac
