#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if [[ -d "$VENV_DIR" ]] && ! ("$VENV_DIR/bin/python3" -c 'import sys') >/dev/null 2>&1; then
    echo "Recreating broken venv at $VENV_DIR..."
    rm -rf "$VENV_DIR"
fi

if [[ ! -d "$VENV_DIR" ]]; then
    echo "Creating venv at $VENV_DIR..."
    "$PYTHON_BIN" -m venv --symlinks "$VENV_DIR"
fi

"$VENV_DIR/bin/python3" -m pip install --quiet --upgrade pip
"$VENV_DIR/bin/python3" -m pip install --quiet -r "$SCRIPT_DIR/requirements.txt"
echo "Release tooling ready at $VENV_DIR"
