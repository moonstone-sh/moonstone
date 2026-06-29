#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON="$SCRIPT_DIR/.venv/bin/python3"
RELEASE_HOST="${MOONSTONE_RELEASE_HOST:-vps}"
RELEASES_PATH="${MOONSTONE_RELEASES_PATH:-/home/moonstone/moonstone.sh/public/releases}"

if [[ ! -x "$PYTHON" ]]; then
    echo "error: release venv is missing; run ./release-tools/setup-venv.sh" >&2
    exit 1
fi

cd "$PROJECT_ROOT"
zig build
VERSION="$($PYTHON "$SCRIPT_DIR/package-release.py" --print-version)"
REMOTE_LATEST="$(ssh "$RELEASE_HOST" "cat '$RELEASES_PATH/latest' 2>/dev/null || true")"
if [[ -n "$REMOTE_LATEST" ]]; then
    "$PYTHON" "$SCRIPT_DIR/check-newer-version.py" "$VERSION" "$REMOTE_LATEST"
fi

REMOTE_RELEASE="$RELEASES_PATH/$VERSION"
"$PYTHON" "$SCRIPT_DIR/package-release.py" --overwrite
ssh "$RELEASE_HOST" "mkdir -p '$RELEASES_PATH' && test ! -e '$REMOTE_RELEASE' && mkdir '$REMOTE_RELEASE'" || {
    echo "error: remote release already exists or could not be created: $RELEASE_HOST:$REMOTE_RELEASE" >&2
    exit 1
}

rsync -avz "dist/releases/$VERSION/" "$RELEASE_HOST:$REMOTE_RELEASE/"
LATEST_FILE="$(mktemp)"
trap 'rm -f "$LATEST_FILE"' EXIT
printf '%s\n' "$VERSION" > "$LATEST_FILE"
REMOTE_TMP="$RELEASES_PATH/.latest.$$"
rsync -avz "$LATEST_FILE" "$RELEASE_HOST:$REMOTE_TMP"
ssh "$RELEASE_HOST" "mv '$REMOTE_TMP' '$RELEASES_PATH/latest'"
echo "Published Moonstone $VERSION to $RELEASE_HOST:$REMOTE_RELEASE"
