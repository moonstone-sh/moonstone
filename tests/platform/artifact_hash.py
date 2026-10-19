"""Portable streaming hash contract, including binary and spaced file paths."""
import json
from pathlib import Path
import subprocess
import tempfile
import blake3

repo = Path(__file__).resolve().parents[2]
moon = repo / 'zig-out/bin' / ('moon.exe' if __import__('os').name == 'nt' else 'moon')
with tempfile.TemporaryDirectory(prefix='moon hash ') as directory:
    sample = Path(directory) / 'sample with spaces.bin'
    for data in (b'', b'hello', bytes(range(256)) * 1025):
        sample.write_bytes(data)
        result = json.loads(subprocess.check_output([str(moon), 'artifact', 'hash', '--json', '--', str(sample)], text=True, timeout=30))
        assert result == {'contract': 'moonstone:artifact-hash:v1', 'bytes': len(data), 'b3': 'b3:' + blake3.blake3(data).hexdigest()}, result
    sample.unlink()
    missing = subprocess.run([str(moon), 'artifact', 'hash', '--', str(sample)], capture_output=True, timeout=30)
    assert missing.returncode != 0 and not missing.stdout.strip(), missing
print('PASS: portable artifact hash contract')
