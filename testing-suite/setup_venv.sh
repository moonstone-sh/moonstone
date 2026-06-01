#!/usr/bin/env bash
set -euo pipefail

# This script sets up a Python virtual environment for the Moonstone testing suite.
# It installs all necessary dependencies for registry building and sandbox management.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"

# Ensure we are in the right directory
cd "${SCRIPT_DIR}"

if [[ -d "$VENV_DIR" ]]; then
    echo "--- Virtual environment already exists at ${VENV_DIR}"
else
    echo "--- Creating virtual environment at ${VENV_DIR}..."
    python3 -m venv "$VENV_DIR"
fi

echo "--- Updating dependencies..."
source "$VENV_DIR/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet -r "${SCRIPT_DIR}/registry-requirements.txt"

echo ""
echo "✅ Testing suite environment is ready."
echo "To activate: source testing-suite/.venv/bin/activate"
echo "To build registry: ./testing-suite/run_lua_tool.sh registry-builder"
echo "To setup sandbox: ./testing-suite/run_lua_tool.sh generate-sandbox"
