#!/usr/bin/env python3
"""Manage the fixtures/sandbox directory for Moonstone battle testing.

Copies the structure from fixtures/sandbox-reference into fixtures/sandbox.
"""

import argparse
import os
import shutil
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
SANDBOX = os.path.join(PROJECT_ROOT, "fixtures", "sandbox")
REFERENCE = os.path.join(PROJECT_ROOT, "fixtures", "sandbox-reference")


def setup_sandbox(clean: bool = False) -> None:
    """Setup the sandbox by copying from reference."""
    if clean and os.path.exists(SANDBOX):
        print(f"--- Cleaning existing sandbox at {SANDBOX}")
        shutil.rmtree(SANDBOX)

    if not os.path.exists(REFERENCE):
        print(f"ERROR: Reference directory not found at {REFERENCE}")
        sys.exit(1)

    print(f"--- Synchronizing sandbox from {REFERENCE}")
    
    # Simple copytree if sandbox doesn't exist, otherwise we might want a more surgical sync
    # but for simplicity and correctness as requested:
    if os.path.exists(SANDBOX):
        # We might want to keep some things like 'registry' if it was built?
        # The user wants to "work easier on structure and file correctness"
        # Let's preserve 'registry' and 'artifacts' if they exist, but update projects.
        projects = ["my-lib", "my-app"]
        for project in projects:
            src = os.path.join(REFERENCE, project)
            dst = os.path.join(SANDBOX, project)
            if os.path.exists(src):
                if os.path.exists(dst):
                    shutil.rmtree(dst)
                shutil.copytree(src, dst)
                print(f"  Updated project: {project}")
        
        # Also copy the top level scripts if they exist in reference
        for item in os.listdir(REFERENCE):
            if item.endswith(".sh"):
                shutil.copy2(os.path.join(REFERENCE, item), os.path.join(SANDBOX, item))
                print(f"  Updated script: {item}")
    else:
        shutil.copytree(REFERENCE, SANDBOX)
        print(f"  Initialized sandbox from reference")

    print("\n✅ Sandbox ready.")


def main() -> int:
    parser = argparse.ArgumentParser(description="Manage Moonstone sandbox")
    parser.add_argument("--clean", action="store_true", help="Remove existing sandbox before setup")
    args = parser.parse_args()

    setup_sandbox(clean=args.clean)
    return 0


if __name__ == "__main__":
    sys.exit(main())
