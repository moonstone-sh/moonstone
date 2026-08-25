#!/usr/bin/env python3
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import re
import shutil
import tarfile
from pathlib import Path

from blake3 import blake3


ROOT = Path(__file__).resolve().parents[2]
VERSION_PATTERN = re.compile(r'^\s*\.version\s*=\s*"([^"]+)"', re.MULTILINE)


def read_version() -> str:
    zon = (ROOT / "build.zig.zon").read_text(encoding="utf-8")
    match = VERSION_PATTERN.search(zon)
    if not match:
        raise SystemExit("error: could not read .version from build.zig.zon")
    return match.group(1)


def digest(path: Path) -> tuple[str, str]:
    sha256 = hashlib.sha256()
    b3 = blake3()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            sha256.update(chunk)
            b3.update(chunk)
    return sha256.hexdigest(), b3.hexdigest()


def write_archive(binary: Path, archive: Path, entry_name: str = "moon") -> None:
    payload = binary.read_bytes()
    info = tarfile.TarInfo(entry_name)
    info.size = len(payload)
    info.mode = 0o755
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = 0

    with archive.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as tar:
                tar.addfile(info, io.BytesIO(payload))


def package_release(output_root: Path, bin_dir: Path, version: str, overwrite: bool) -> Path:
    prefix = f"moon-{version}-"
    binaries = sorted(path for path in bin_dir.glob(f"{prefix}*") if path.is_file())
    if not binaries:
        raise SystemExit(f"error: no binaries matching {bin_dir / (prefix + '*')}; run zig build release first")

    release_dir = output_root / version
    if release_dir.exists():
        if not overwrite:
            raise SystemExit(f"error: release directory already exists: {release_dir}; pass --overwrite to replace it")
        shutil.rmtree(release_dir)
    release_dir.mkdir(parents=True)

    artifacts = []
    sha_lines = []
    b3_lines = []
    for binary in binaries:
        filename = binary.name
        if filename.endswith(".pdb"):
            continue
        is_windows = "windows" in filename or binary.suffix == ".exe"
        entry_name = "moon.exe" if is_windows else "moon"

        if filename.endswith(".exe"):
            filename = filename[:-4]
        if not filename.startswith(prefix):
            continue
        target = filename[len(prefix):]
        archive_name = f"moon-v{version}-{target}.tar.gz"
        archive = release_dir / archive_name
        write_archive(binary, archive, entry_name=entry_name)
        sha256, b3_hash = digest(archive)
        artifacts.append({
            "name": archive_name,
            "target": target,
            "bytes": archive.stat().st_size,
            "b3": f"b3:{b3_hash}",
            "sha256": f"sha256:{sha256}",
        })
        sha_lines.append(f"{sha256}  {archive_name}\n")
        b3_lines.append(f"{b3_hash}  {archive_name}\n")

    manifest = {"version": version, "artifacts": artifacts}
    (release_dir / "release-manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    (release_dir / "SHA256SUMS").write_text("".join(sha_lines), encoding="utf-8")
    (release_dir / "B3SUMS").write_text("".join(b3_lines), encoding="utf-8")
    return release_dir


def main() -> None:
    parser = argparse.ArgumentParser(description="Package Moonstone release archives and manifests")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist" / "releases")
    parser.add_argument("--bin-dir", type=Path, default=ROOT / "zig-out" / "bin")
    parser.add_argument("--version")
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--print-version", action="store_true")
    args = parser.parse_args()
    version = args.version or read_version()
    if args.print_version:
        print(version)
        return
    print(package_release(args.output_dir, args.bin_dir, version, args.overwrite))


if __name__ == "__main__":
    main()
