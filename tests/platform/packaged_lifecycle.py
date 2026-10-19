"""Run public-command scenarios from a release-format archive, not the build tree."""
import importlib.util
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('package_release', ROOT / 'scripts/release/package-release.py')
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)
name = 'moon.exe' if os.name == 'nt' else 'moon'
with tempfile.TemporaryDirectory(prefix='moon-packaged-lifecycle-') as tmp:
    root = Path(tmp)
    archive = root / 'moon.tar.gz'
    packager.write_archive(ROOT / 'zig-out/bin' / name, archive, name)
    digest, _ = packager.digest(archive)
    assert len(digest) == 64
    with tarfile.open(archive, 'r:gz') as tar:
        assert tar.getnames() == [name]
        tar.extractall(root / 'extracted', filter='data')
    moon = root / 'extracted' / name
    # Debug Windows builds keep symbols beside the executable, outside the
    # public archive. Preserve them for actionable unexpected-failure traces.
    if os.name == 'nt':
        for symbols in (ROOT / 'zig-out/bin').glob('moon*.pdb'):
            shutil.copy2(symbols, moon.parent / symbols.name)
    subprocess.run([str(moon), 'version'], check=True)
    subprocess.run([sys.executable, str(ROOT / 'tests/platform/lifecycle.py')],
                   env=dict(os.environ, MOON_BIN=str(moon)), check=True)
