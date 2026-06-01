#!/usr/bin/env python3
"""Plain fetcher for Moonstone registry artifacts.

Downloads upstream source tarballs to a local cache.  Used by registry-builder.py
to construct faithful registry fixtures.

Usage:
    import fetch_registry_artifacts as fetcher
    fetcher.download_all("./cache")

CLI:
    python3 testing-suite/fetch-registry_artifacts.py --cache-dir ./cache
"""

import argparse
import os
import sys
import time

try:
    import requests
    HAS_REQUESTS = True
except ImportError:
    HAS_REQUESTS = False

# ── Artifact Catalog ─────────────────────────────────────────────────────────
ARTIFACTS = {
    "lua": {
        "kind": "runtime",
        "description": "Lua programming language runtime",
        "versions": {
            "5.4.7": {
                "url": "https://www.lua.org/ftp/lua-5.4.7.tar.gz",
            },
            "5.4.6": {
                "url": "https://www.lua.org/ftp/lua-5.4.6.tar.gz",
            },
        },
    },
    "inspect": {
        "kind": "lib",
        "description": "Human-readable representation of Lua tables",
        "versions": {
            "3.1.3": {
                "url": "https://github.com/kikito/inspect.lua/archive/refs/tags/v3.1.3.tar.gz",
            },
            "3.1.2": {
                "url": "https://github.com/kikito/inspect.lua/archive/refs/tags/v3.1.2.tar.gz",
            },
        },
    },
    "luassert": {
        "kind": "lib",
        "description": "Assertion library for Lua",
        "versions": {
            "1.9.0": {
                "url": "https://github.com/Olivine-Labs/luassert/archive/refs/tags/v1.9.0.tar.gz",
            },
            "1.8.0": {
                "url": "https://github.com/Olivine-Labs/luassert/archive/refs/tags/v1.8.0.tar.gz",
            },
        },
    },
}


# ── Download ─────────────────────────────────────────────────────────────────
def _get_session():
    if not HAS_REQUESTS:
        raise RuntimeError(
            "requests is required. Install: pip install requests\n"
            "Or run: ./scripts/setup_venv.sh"
        )
    session = requests.Session()
    retry = requests.packages.urllib3.util.retry.Retry(
        total=3,
        backoff_factor=1,
        status_forcelist=[500, 502, 503, 504],
    )
    adapter = requests.adapters.HTTPAdapter(max_retries=retry)
    session.mount("http://", adapter)
    session.mount("https://", adapter)
    return session


def download(name: str, version: str, cache_dir: str, force: bool = False) -> str:
    """Download a single artifact to the cache. Returns path to cached file."""
    info = ARTIFACTS[name]["versions"][version]
    url = info["url"]
    cache_path = os.path.join(cache_dir, f"{name}-{version}.tar.gz")

    if os.path.exists(cache_path) and not force:
        return cache_path

    os.makedirs(cache_dir, exist_ok=True)
    print(f"[fetch] {name}@{version} from {url}")

    session = _get_session()
    response = session.get(url, stream=True, timeout=60)
    response.raise_for_status()

    with open(cache_path, "wb") as f:
        for chunk in response.iter_content(chunk_size=65536):
            f.write(chunk)

    print(f"[fetch] cached: {cache_path}")
    return cache_path


def download_all(cache_dir: str, force: bool = False) -> list[str]:
    """Download all artifacts to the cache. Returns list of cached file paths."""
    paths = []
    for name, info in ARTIFACTS.items():
        for version in info["versions"]:
            paths.append(download(name, version, cache_dir, force))
    return paths


# ── CLI ──────────────────────────────────────────────────────────────────────
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Fetch upstream artifacts for Moonstone registry"
    )
    parser.add_argument(
        "--cache-dir", "-c", required=True,
        help="Cache directory for downloaded tarballs"
    )
    parser.add_argument(
        "--force", "-f", action="store_true",
        help="Re-download existing files"
    )
    args = parser.parse_args()

    try:
        download_all(args.cache_dir, args.force)
        print("All artifacts fetched.")
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
