#!/usr/bin/env python3
"""Verify and execute an exact candidate release archive before publication."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

release, target = Path(sys.argv[1]), sys.argv[2]
manifest = json.loads((release / 'release-manifest.json').read_text())
artifact = next(item for item in manifest['artifacts'] if item['target'] == target)
archive = release / artifact['name']
assert hashlib.sha256(archive.read_bytes()).hexdigest() == artifact['sha256'].removeprefix('sha256:')
expected = 'moon.exe' if 'windows' in target else 'moon'
with tempfile.TemporaryDirectory(prefix='moon-release-candidate-') as tmp:
    with tarfile.open(archive, 'r:gz') as tar:
        assert tar.getnames() == [expected]
        tar.extractall(tmp, filter='data')
    moon = Path(tmp) / expected
    version = subprocess.check_output([str(moon), 'version'], text=True)
    assert f"v{manifest['version']} " in version, version
    assert f"({manifest['build_label']})" in version, version
    root = Path(__file__).resolve().parents[2]
    subprocess.run([sys.executable, str(root / 'tests/platform/lifecycle.py')],
                   env=dict(os.environ, MOON_BIN=str(moon)), check=True)
