"""Exercise deferred Windows self-update against an isolated HTTP installer."""
import functools
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time


def main():
    with tempfile.TemporaryDirectory(prefix="moon update ü ") as tmp:
        root = Path(tmp)
        marker = root / "updated.txt"
        (root / "install.ps1").write_text(
            "param([string]$InstallDir,[string]$Version,[switch]$Latest,[switch]$NoModifyPath)\n"
            "$ErrorActionPreference='Stop'\n"
            "if ($Version -eq '0.0.0-fail') { throw 'fixture installer failure' }\n"
            "if (-not $NoModifyPath) { throw 'Must preserve PATH' }\n"
            "Set-Content -LiteralPath (Join-Path $InstallDir 'updated.txt') -Value $Version\n",
            encoding="utf-8",
        )
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=tmp)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f"http://127.0.0.1:{server.server_port}/install.ps1"
            subprocess.run(["zig", "build", "-Doptimize=ReleaseSafe", f"-Ddefault-windows-installer-url={url}"], check=True)
            moon = root / "moon.exe"
            shutil.copy2("zig-out/bin/moon.exe", moon)
            env = dict(os.environ, MOONSTONE_HOME=str(root / "home"))
            for version, expected in [("0.7.0", "completed"), ("0.0.0-fail", "fixture installer failure")]:
                proc = subprocess.run([str(moon), "self", "install", "--version", version, "--apply", "--json"], env=env, capture_output=True, check=True)
                rows = [json.loads(line) for line in proc.stdout.decode("utf-8").splitlines()]
                result = rows[-1]
                assert result["value"] == "scheduled", result
                # The public envelope stores command payload under data.
                payload = result.get("data", result.get("meta", {}))
                log_path = payload.get("log")
                if not log_path:
                    # Do not depend on the envelope's payload key in the fixture.
                    def find_log(value):
                        if isinstance(value, dict):
                            if "log" in value: return value["log"]
                            for child in value.values():
                                found = find_log(child)
                                if found: return found
                    log_path = find_log(result)
                assert log_path, result
                log = Path(log_path)
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    text = log.read_text(encoding="utf-16", errors="replace") if log.exists() else ""
                    if expected in text: break
                    time.sleep(0.1)
                else:
                    raise AssertionError(f"Update never recorded {expected}: {text}")
                if version == "0.7.0": assert marker.exists()
                log.unlink(missing_ok=True)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
