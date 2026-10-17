import hashlib
import importlib.util
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("package_release", Path(__file__).with_name("package-release.py"))
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class ReleasePackageTest(unittest.TestCase):
    def test_reissued_release_records_identity_and_checksums(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binaries = root / "bin"
            binaries.mkdir()
            for target in ("aarch64-macos", "x86_64-windows-gnu.exe"):
                (binaries / f"moon-0.7.0-{target}").write_bytes(b"fixture executable\n")
            output = packager.package_release(root / "releases", binaries, "0.7.0", False, 1, "a" * 40, "standalone-reissue.1")
            manifest = json.loads((output / "release-manifest.json").read_text())
            self.assertEqual(manifest["version"], "0.7.0")
            self.assertEqual(manifest["release_revision"], 1)
            self.assertEqual(manifest["source_commit"], "a" * 40)
            self.assertEqual(manifest["build_label"], "standalone-reissue.1")
            self.assertEqual(len(manifest["artifacts"]), 2)
            for artifact in manifest["artifacts"]:
                archive = output / artifact["name"]
                self.assertEqual(artifact["sha256"], "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest())
                with tarfile.open(archive) as contents:
                    name = "moon.exe" if "windows" in artifact["target"] else "moon"
                    self.assertEqual(contents.getnames(), [name])
                    self.assertEqual(contents.extractfile(name).read(), b"fixture executable\n")
            before = (output / "SHA256SUMS").read_bytes()
            packager.package_release(root / "releases", binaries, "0.7.0", True, 1, "a" * 40, "standalone-reissue.1")
            self.assertEqual((output / "SHA256SUMS").read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
