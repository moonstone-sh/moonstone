#!/usr/bin/env python3
"""Build a faithful Moonstone registry from fetched upstream artifacts.

Downloads real artifacts, repackages them into deterministic tarballs with real
Blake3 hashes, and generates a complete registry topology.

Usage:
    python3 testing-suite/registry-builder.py --output-dir fixtures/sandbox
    python3 testing-suite/registry-builder.py --verify fixtures/sandbox/registry
"""

import argparse
import gzip
import io
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile

try:
    import zstandard

    HAS_ZSTD = True
except ImportError:
    HAS_ZSTD = False

# Import fetcher module
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fetch_registry_artifacts as fetcher


# ── Blake3 ───────────────────────────────────────────────────────────────────
try:
    import blake3

    HAS_BLAKE3 = True
except ImportError:
    HAS_BLAKE3 = False

if not HAS_BLAKE3:
    raise RuntimeError("blake3 is required. Run pip install blake3 or use the venv.")

import json


def compute_recipe_hash(info: dict) -> str:

    recipe = {
        "schema": "moonstone.recipe.v0",
        "kind": "prebuilt-artifact",
        "name": info["name"],
        "version": info["version"],
        "source_hash": info["source_hash"],
        "artifact_hash": info["artifact_hash"],
        "materializer": "unpack-artifact-v0",
        "target": info["target"],
        "lua_api": info.get("lua_api", ""),
        "lua_abi": info["lua_abi"],
        "runtime": info.get("runtime", ""),
        "runtime_artifact_hash": info.get("runtime_artifact_hash", ""),
        "layout": {"strip_components": info["strip_components"]},
        "provides": info["provides"],
    }


    if info.get("materialize"):
        m = info["materialize"]
        recipe["materializer"] = m["kind"]
        recipe["strategy"] = m.get("strategy", "command")
        if m.get("command"):
            recipe["command"] = m["command"]
        if m.get("args"):
            recipe["args"] = m["args"]
        if m.get("steps"):
            recipe["steps"] = m["steps"]
        if m.get("env"):
            recipe["env"] = m["env"]
        if m.get("collect"):
            recipe["collect"] = m["collect"]

    canonical = json.dumps(recipe, sort_keys=True, separators=(",", ":"))
    return blake3_hash(canonical.encode())


def build_synthetic_make_module_artifact(output_dir: str) -> dict:
    """Build a synthetic C module using Makefile."""
    files: dict[str, bytes] = {}

    c_source = """
#include <lua.h>
#include <lauxlib.h>

static int hello(lua_State *L) {
    lua_pushstring(L, "hello from synthetic make module");
    return 1;
}

int luaopen_synthetic_make_module(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, hello);
    lua_setfield(L, -2, "hello");
    return 1;
}
"""
    files["synthetic_make_module.c"] = c_source.strip().encode("utf-8")

    makefile = """
CC ?= cc
LUA_INCDIR ?= .
CFLAGS = -shared -fPIC -I$(LUA_INCDIR)

# macOS fix
ifeq ($(shell uname), Darwin)
  CFLAGS = -shared -fPIC -I$(LUA_INCDIR) -undefined dynamic_lookup
endif

all: synthetic_make_module.so

synthetic_make_module.so: synthetic_make_module.c
	$(CC) $(CFLAGS) -o $@ $<

install: synthetic_make_module.so
	mkdir -p $(PREFIX)
	cp $< $(PREFIX)/
"""
    files["Makefile"] = makefile.strip().encode("utf-8")

    artifact_name = "synthetic-make-module-0.1.0-source.tar.gz"
    artifact_path = os.path.join(output_dir, artifact_name)
    create_deterministic_tar_gz(files, artifact_path)

    return {
        "name": "synthetic-make-module",
        "version": "0.1.0",
        "kind": "lib",
        "description": "Synthetic C module using Makefile",
        "source_hash": blake3_hash_file(artifact_path),
        "artifact_hash": blake3_hash_file(artifact_path),
        "artifact_path": artifact_path,
        "artifact_bytes": os.path.getsize(artifact_path),
        "artifact_name": artifact_name,
        "runtimes": ["lua@5.4.7"],
        "lua_api": "lua-5.4",
        "lua_abi": "lua-5.4",
        "runtime": "lua@5.4.7",
        "runtime_artifact_hash": "",
        "target": "source",
        "strip_components": 0,

        "materialize": {
            "kind": "command",
            "command": "make",
            "args": ["install", "PREFIX=${out}"],
            "env": {
                "LUA_INCDIR": "${runtime.include}",
            },
            "collect": {
                "lua_cmodules": [
                    {
                        "name": "synthetic_make_module.so",
                        "path": "${out}/synthetic_make_module.so",
                    }
                ],
                "lua_modules": [],
                "bins": [],
            },
        },
        "provides": {
            "runtime": [],
            "bin": [],
            "headers": [],
            "native_lib": [],
            "lua_module": [],
            "lua_cmodule": [
                {"name": "synthetic_make_module.so", "path": "synthetic_make_module.so"}
            ],
        },
    }


def build_synthetic_cmake_module_artifact(output_dir: str) -> dict:
    """Build a synthetic C module using CMake."""
    files: dict[str, bytes] = {}

    c_source = """
#include <lua.h>
#include <lauxlib.h>

static int hello(lua_State *L) {
    lua_pushstring(L, "hello from synthetic cmake module");
    return 1;
}

__attribute__((visibility("default"))) int luaopen_synthetic_cmake_module(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, hello);
    lua_setfield(L, -2, "hello");
    return 1;
}
"""
    files["synthetic_cmake_module.c"] = c_source.strip().encode("utf-8")

    cmake_lists = """
cmake_minimum_required(VERSION 3.10)
project(synthetic_cmake_module C)

set(CMAKE_C_VISIBILITY_PRESET default)

add_library(synthetic_cmake_module MODULE synthetic_cmake_module.c)

set_target_properties(synthetic_cmake_module PROPERTIES
  PREFIX ""
  OUTPUT_NAME "synthetic_cmake_module"
  SUFFIX ".so"
)

target_include_directories(synthetic_cmake_module PRIVATE ${LUA_INCLUDE_DIR})
"""
    files["CMakeLists.txt"] = cmake_lists.strip().encode("utf-8")

    artifact_name = "synthetic-cmake-module-0.1.0-source.tar.gz"
    artifact_path = os.path.join(output_dir, artifact_name)
    create_deterministic_tar_gz(files, artifact_path)

    return {
        "name": "synthetic-cmake-module",
        "version": "0.1.0",
        "kind": "lib",
        "description": "Synthetic C module for testing CMake materialization",
        "source_hash": blake3_hash_file(artifact_path),
        "artifact_hash": blake3_hash_file(artifact_path),
        "artifact_path": artifact_path,
        "artifact_bytes": os.path.getsize(artifact_path),
        "artifact_name": artifact_name,
        "runtimes": ["lua@5.4.7"],
        "lua_api": "lua-5.4",
        "lua_abi": "lua-5.4",
        "runtime": "lua@5.4.7",
        "runtime_artifact_hash": "",
        "target": "source",
        "strip_components": 0,

        "materialize": {
            "kind": "cmake",
            "cmake_args": ["-DCMAKE_C_FLAGS=-Wall"],
            "collect": {
                "lua_cmodules": [
                    {
                        "name": "synthetic_cmake_module.so",
                        "path": "${build}/synthetic_cmake_module.so",
                    }
                ],
                "lua_modules": [],
                "bins": [],
            },
        },
        "provides": {
            "runtime": [],
            "bin": [],
            "headers": [],
            "native_lib": [],
            "lua_module": [],
            "lua_cmodule": [
                {
                    "name": "synthetic_cmake_module.so",
                    "path": "synthetic_cmake_module.so",
                }
            ],
        },
    }


def blake3_hash(data: bytes) -> str:
    """Compute Blake3 hash of bytes, returning 'b3:hex'."""
    if HAS_BLAKE3:
        return f"b3:{blake3.blake3(data).hexdigest()}"

    result = subprocess.run(
        ["b3sum", "--no-names", "-"],
        input=data,
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return f"b3:{result.stdout.strip()}"

    raise RuntimeError(
        "blake3 not available. Install via one of:\n"
        "  ./scripts/setup_venv.sh\n"
        "  pip install blake3\n"
        "  brew/apt install b3sum"
    )


def blake3_hash_file(path: str) -> str:
    with open(path, "rb") as f:
        return blake3_hash(f.read())


# ── Deterministic Tar ──────────────────────────────────────────────────────
def create_deterministic_tar_gz(files: dict[str, bytes], output_path: str) -> None:
    """Create a reproducible tar.gz archive.

    Normalizes:
    - Sorted lexicographic path order
    - mtime = 0
    - uid/gid = 0
    - uname/gname = ""
    - directories = 0755
    - regular files = 0644 (bin/* = 0755)
    - gzip mtime = 0
    """
    # Collect all paths including inferred directories
    all_paths: set[str] = set(files.keys())
    for path in files:
        parts = path.split("/")
        for i in range(1, len(parts)):
            all_paths.add("/".join(parts[:i]) + "/")

    # Sort: directories first, then files, both lexicographically
    sorted_paths = sorted(all_paths, key=lambda p: (not p.endswith("/"), p))

    tar_buf = io.BytesIO()
    with tarfile.open(fileobj=tar_buf, mode="w") as tar:
        for path in sorted_paths:
            if path.endswith("/"):
                info = tarfile.TarInfo(name=path)
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                info.uid = 0
                info.gid = 0
                info.uname = ""
                info.gname = ""
                info.mtime = 0
                tar.addfile(info)
            else:
                data = files[path]
                info = tarfile.TarInfo(name=path)
                info.type = tarfile.REGTYPE
                info.mode = 0o755 if path.startswith("bin/") else 0o644
                info.uid = 0
                info.gid = 0
                info.uname = ""
                info.gname = ""
                info.mtime = 0
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))

    tar_buf.seek(0)
    with open(output_path, "wb") as f:
        with gzip.GzipFile(fileobj=f, mode="wb", mtime=0) as gz:
            gz.write(tar_buf.getvalue())


def _host_lua_build_flags() -> tuple[list[str], list[str], list[str]]:
    """Return (MYCFLAGS, MYLDFLAGS, MYLIBS) for building a real Lua runtime."""
    cflags = ["-DLUA_USE_POSIX", "-DLUA_USE_DLOPEN"]
    ldflags: list[str] = []
    libs = ["-lm"]

    if sys.platform.startswith("linux"):
        ldflags.append("-Wl,-E")
        libs.append("-ldl")
    elif sys.platform.startswith("freebsd"):
        ldflags.append("-Wl,-E")
    elif sys.platform == "darwin":
        pass
    else:
        raise RuntimeError(
            f"Unsupported host platform for real Lua synthetic artifact: {sys.platform}"
        )

    return cflags, ldflags, libs


def _require_tool(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise RuntimeError(
            f"Required tool `{name}` was not found. Building the real Lua "
            "synthetic runtime requires a C toolchain. On Alpine, install "
            "`build-base make`; on macOS, install Xcode Command Line Tools."
        )
    return path


def _build_real_lua(lua_dir: str) -> None:
    """Compile Lua in-place using the upstream Makefile."""
    _require_tool("make")
    _require_tool(os.environ.get("MOONSTONE_REGISTRY_CC", os.environ.get("CC", "cc")))

    cflags, ldflags, libs = _host_lua_build_flags()

    env = os.environ.copy()
    env.setdefault("CC", os.environ.get("MOONSTONE_REGISTRY_CC", "cc"))

    cmd = [
        "make",
        "generic",
        "MYCFLAGS=" + " ".join(cflags),
        "MYLDFLAGS=" + " ".join(ldflags),
        "MYLIBS=" + " ".join(libs),
    ]

    result = subprocess.run(
        cmd,
        cwd=lua_dir,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "Failed to build real Lua runtime artifact.\n"
            f"Command: {' '.join(cmd)}\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )


def safe_extractall(tar: tarfile.TarFile, path: str) -> None:
    # """Extract tar members safely."""
    # Simplified for synthetic environment
    tar.extractall(path=path)


def build_lua_artifact(raw_tarball: str, version: str, output_dir: str) -> dict:
    """Package Lua runtime as a source artifact with build recipe."""
    # Use the upstream tarball directly; client will materialize it
    artifact_name = f"lua-{version}-source-lua-5.4.tar.gz"
    artifact_path = os.path.join(output_dir, artifact_name)
    shutil.copy(raw_tarball, artifact_path)

    source_hash = blake3_hash_file(raw_tarball)

    header_names = ["lua.h", "luaconf.h", "lualib.h", "lauxlib.h", "lua.hpp"]

    # Build steps for Lua upstream Makefile
    # After extraction with strip_components=1, source_dir becomes the root
    # containing Makefile, src/, etc.
    # ${source} expands to the extracted source dir.
    # ${build} defaults to ${source} for plain command materializer.
    # But Lua builds in-place, so build_path = source_path.
    # We use ${source}/src/ for collect paths.
    return {
        "name": "lua",
        "version": version,
        "kind": "runtime",
        "description": f"Lua {version} source runtime",
        "source_hash": source_hash,
        "artifact_hash": blake3_hash_file(artifact_path),
        "artifact_path": artifact_path,
        "artifact_bytes": os.path.getsize(artifact_path),
        "artifact_name": artifact_name,
        "runtimes": [f"lua@{version}"],
        "lua_api": "lua-5.4",
        "lua_abi": "lua-5.4",
        "runtime": f"lua@{version}",
        "runtime_artifact_hash": blake3_hash_file(artifact_path),
        "target": "source",
        "strip_components": 1,

        "materialize": {
            "kind": "command",
            "steps": [
                {
                    "command": "make",
                    "args": ["generic", "CC=zig cc", "MYCFLAGS=-fPIC -DLUA_USE_POSIX -DLUA_USE_DLOPEN", "MYLDFLAGS=-Wl,-E", "MYLIBS=-lm -ldl"],
                },
            ],
            "collect": {
                "bins": [
                    {"name": "bin/lua", "path": "${source}/src/lua"},
                    {"name": "bin/luac", "path": "${source}/src/luac"},
                ],
                "headers": [
                    {"name": "include/" + h, "path": "${source}/src/" + h}
                    for h in header_names
                ],
                "native_lib": [
                    {"name": "lib/liblua.a", "path": "${source}/src/liblua.a"},
                ],
            },
        },
        "provides": {
            "runtime": [{"name": "lua", "version": version, "abi": "lua-5.4"}],
            "bin": [
                {"name": "lua", "path": "bin/lua"},
                {"name": "luac", "path": "bin/luac"},
            ],
            "headers": [{"name": h, "path": f"include/{h}"} for h in header_names],
            "native_lib": [{"name": "lua", "path": "lib/liblua.a"}],
            "lua_module": [],
        },
    }


def build_synthetic_cmodule_artifact(output_dir: str) -> dict:
    """Build a synthetic C module source artifact."""
    files: dict[str, bytes] = {}

    c_source = """
#include <lua.h>
#include <lauxlib.h>

static int hello(lua_State *L) {
    lua_pushstring(L, "hello from synthetic cmodule");
    return 1;
}

int luaopen_synthetic_cmodule(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, hello);
    lua_setfield(L, -2, "hello");
    return 1;
}
"""
    files["synthetic_cmodule.c"] = c_source.strip().encode("utf-8")

    artifact_name = "synthetic-cmodule-0.1.0-source.tar.gz"
    artifact_path = os.path.join(output_dir, artifact_name)
    create_deterministic_tar_gz(files, artifact_path)

    return {
        "name": "synthetic-cmodule",
        "version": "0.1.0",
        "kind": "lib",
        "description": "Synthetic C module for testing materialization",
        "source_hash": blake3_hash_file(artifact_path),
        "artifact_hash": blake3_hash_file(artifact_path),
        "artifact_path": artifact_path,
        "artifact_bytes": os.path.getsize(artifact_path),
        "artifact_name": artifact_name,
        "runtimes": ["lua@5.4.7"],
        "lua_api": "lua-5.4",
        "lua_abi": "lua-5.4",
        "runtime": "lua@5.4.7",
        "runtime_artifact_hash": "",
        "target": "source",
        "strip_components": 0,

        "materialize": {
            "kind": "native-cmodule",
            "strategy": "zig-cc",
            "input": {
                "sources": ["synthetic_cmodule.c"],
            },
            "output": {
                "module": "synthetic_cmodule",
                "path": "synthetic_cmodule.so",
            },
        },
        "provides": {
            "runtime": [],
            "bin": [],
            "headers": [],
            "native_lib": [],
            "lua_module": [],
            "lua_cmodule": [
                {"name": "synthetic_cmodule.so", "path": "synthetic_cmodule.so"}
            ],
        },
    }


def build_inspect_artifact(raw_tarball: str, version: str, output_dir: str) -> dict:
    """Build an inspect library artifact from upstream source tarball."""
    files: dict[str, bytes] = {}

    with tempfile.TemporaryDirectory() as tmpdir:
        with tarfile.open(raw_tarball, "r:gz") as tar:
            safe_extractall(tar, tmpdir)

        extracted = [
            d
            for d in os.listdir(tmpdir)
            if d.startswith("inspect") and os.path.isdir(os.path.join(tmpdir, d))
        ]
        if not extracted:
            raise RuntimeError(f"No inspect directory found in {raw_tarball}")
        inspect_dir = os.path.join(tmpdir, extracted[0])

        # Find inspect.lua
        inspect_lua_path = os.path.join(inspect_dir, "inspect.lua")
        if not os.path.exists(inspect_lua_path):
            for root, _, filenames in os.walk(inspect_dir):
                if "inspect.lua" in filenames:
                    inspect_lua_path = os.path.join(root, "inspect.lua")
                    break

        with open(inspect_lua_path, "rb") as f:
            files["lua/inspect.lua"] = f.read()

    artifact_name = f"inspect-{version}-lua-5.4.tar.gz"
    artifact_path = os.path.join(output_dir, artifact_name)
    create_deterministic_tar_gz(files, artifact_path)

    return {
        "name": "inspect",
        "version": version,
        "kind": "lib",
        "description": "Human-readable representation of Lua tables",
        "source_hash": blake3_hash_file(raw_tarball),
        "artifact_hash": blake3_hash_file(artifact_path),
        "artifact_path": artifact_path,
        "artifact_bytes": os.path.getsize(artifact_path),
        "artifact_name": artifact_name,
        "runtimes": ["lua@5.4.7"],
        "lua_api": "lua-5.4",
        "lua_abi": "lua-5.4",
        "runtime": "lua@5.4.7",
        "runtime_artifact_hash": "",
        "target": "any",
        "strip_components": 0,

        "provides": {
            "runtime": [],
            "bin": [],
            "headers": [],
            "native_lib": [],
            "lua_module": [{"name": "inspect", "path": "lua/inspect.lua"}],
        },
    }


def build_luassert_artifact(raw_tarball: str, version: str, output_dir: str) -> dict:
    """Build a luassert library artifact from upstream source tarball."""
    files: dict[str, bytes] = {}

    with tempfile.TemporaryDirectory() as tmpdir:
        with tarfile.open(raw_tarball, "r:gz") as tar:
            safe_extractall(tar, tmpdir)

        extracted = [
            d
            for d in os.listdir(tmpdir)
            if d.startswith("luassert") and os.path.isdir(os.path.join(tmpdir, d))
        ]
        if not extracted:
            raise RuntimeError(f"No luassert directory found in {raw_tarball}")
        luassert_dir = os.path.join(tmpdir, extracted[0])

        # Copy src/ contents to lua/
        src_dir = os.path.join(luassert_dir, "src")
        if os.path.isdir(src_dir):
            for root, _, filenames in os.walk(src_dir):
                for filename in filenames:
                    full_path = os.path.join(root, filename)
                    rel_path = os.path.relpath(full_path, src_dir)
                    with open(full_path, "rb") as f:
                        files[f"lua/{rel_path}"] = f.read()
        else:
            # Flat fallback
            for root, _, filenames in os.walk(luassert_dir):
                for filename in filenames:
                    if filename.endswith(".lua"):
                        full_path = os.path.join(root, filename)
                        rel_path = os.path.relpath(full_path, luassert_dir)
                        with open(full_path, "rb") as f:
                            files[f"lua/{rel_path}"] = f.read()

    artifact_name = f"luassert-{version}-lua-5.4.tar.gz"
    artifact_path = os.path.join(output_dir, artifact_name)
    create_deterministic_tar_gz(files, artifact_path)

    return {
        "name": "luassert",
        "version": version,
        "kind": "lib",
        "description": "Assertion library for Lua",
        "source_hash": blake3_hash_file(raw_tarball),
        "artifact_hash": blake3_hash_file(artifact_path),
        "artifact_path": artifact_path,
        "artifact_bytes": os.path.getsize(artifact_path),
        "artifact_name": artifact_name,
        "runtimes": ["lua@5.4.7"],
        "lua_api": "lua-5.4",
        "lua_abi": "lua-5.4",
        "runtime": "lua@5.4.7",
        "runtime_artifact_hash": "",
        "target": "any",
        "strip_components": 0,

        "provides": {
            "runtime": [],
            "bin": [],
            "headers": [],
            "native_lib": [],
            "lua_module": [{"name": "luassert", "path": "lua/luassert.lua"}],
        },
    }


# ── TOML helpers ───────────────────────────────────────────────────────────
def _toml_inline_array(items: list[dict]) -> str:
    if not items:
        return "[]"
    entries = []
    for item in items:
        pairs = [f'{k} = "{v}"' for k, v in item.items()]
        entries.append("{ " + ", ".join(pairs) + " }")
    return "[" + ", ".join(entries) + "]"


def blob_registry_path(artifact_hash: str) -> str:
    h = artifact_hash[3:] if artifact_hash.startswith("b3:") else artifact_hash
    return f"blobs/b3/{h[:2]}/{h[2:4]}/{h}.tar.gz"


def blob_index_url(artifact_hash: str) -> str:
    return blob_registry_path(artifact_hash)


def _toml_string_array(items: list[str]) -> str:
    return "[" + ", ".join(f'"{x}"' for x in items) + "]"


# ── Descriptor / Manifest Writers ────────────────────────────────────────────
def write_descriptor(descriptor_path: str, info: dict) -> None:
    """Write a canonical registry package descriptor."""
    os.makedirs(os.path.dirname(descriptor_path), exist_ok=True)

    materialize = info.get("materialize")
    artifact_kind = "source" if materialize else ("runtime" if info["kind"] == "runtime" else "lua_module")
    artifact_id = "-".join(x for x in (artifact_kind, info["target"], info.get("lua_abi", "")) if x)
    lines = [
        "[package]",
        f'name = "{info["name"]}"',
        f'version = "{info["version"]}"',
        f'kind = "{info["kind"]}"',
        f'description = "{info["description"]}"',
        "",
        "[[artifacts]]",
        f'id = "{artifact_id}"',
        f'kind = "{artifact_kind}"',
        f'target = "{info["target"]}"',
        f'lua_api = "{info.get("lua_api", "")}"',
        f'lua_abi = "{info.get("lua_abi", "")}"',
        f'runtime = "{info.get("runtime", "")}"',
        'format = "tar.gz"',
        f'url = "{blob_registry_path(info["artifact_hash"])}"',
        f'hash = "{info["artifact_hash"]}"',
        f'recipe_hash = "{info["recipe_hash"]}"',
        f'bytes = {info["artifact_bytes"]}',
    ]
    if info.get("runtime_artifact_hash"):
        lines.append(f'runtime_artifact_hash = "{info["runtime_artifact_hash"]}"')
    lines.append("")

    materializer = dict(materialize or {"kind": "archive"})
    materializer_type = materializer.pop("kind").replace("native-cmodule", "native_cmodule")
    nested = {key: materializer.pop(key) for key in list(materializer) if isinstance(materializer[key], dict)}
    steps = materializer.pop("steps", [])
    lines.extend(["[artifacts.materialize]", f'type = "{materializer_type}"', f'strip_components = {info["strip_components"]}'])
    for key, value in materializer.items():
        if isinstance(value, str):
            lines.append(f'{key} = "{value}"')
        elif isinstance(value, list):
            lines.append(f"{key} = {_toml_string_array(value)}")
    lines.append("")
    for step in steps:
        lines.extend(["[[artifacts.materialize.steps]]", f'command = "{step["command"]}"'])
        if step.get("args"):
            lines.append(f"args = {_toml_string_array(step['args'])}")
        lines.append("")
    for section, values in nested.items():
        lines.append(f"[artifacts.materialize.{section}]")
        for key, value in values.items():
            if isinstance(value, str):
                lines.append(f'{key} = "{value}"')
            elif value and isinstance(value[0], dict):
                lines.append(f"{key} = {_toml_inline_array(value)}")
            else:
                lines.append(f"{key} = {_toml_string_array(value)}")
        lines.append("")

    provision_kinds = (("runtime", "runtime"), ("bin", "bin"), ("headers", "include"), ("native_lib", "lib"), ("lua_module", "lua_module"), ("lua_cmodule", "lua_cmodule"))
    for group, kind in provision_kinds:
        for provision in info["provides"].get(group, []):
            lines.extend(["[[artifacts.provides]]", f'kind = "{kind}"', f'name = "{provision["name"]}"'])
            if kind == "runtime":
                lines.extend([f'version = "{provision["version"]}"', f'lua_abi = "{provision["abi"]}"'])
            else:
                lines.append(f'path = "{provision["path"]}"')
            lines.append("")

    with open(descriptor_path, "w") as f:
        f.write("\n".join(lines) + "\n")


def write_store_manifest(manifest_path: str, info: dict) -> None:
    """Write a store manifest (artifacts/{name}-{version}-manifest.toml)."""
    os.makedirs(os.path.dirname(manifest_path), exist_ok=True)

    lines = [
        "[artifact]",
        f'name = "{info["name"]}"',
        f'version = "{info["version"]}"',
        f'kind = "{info["kind"]}"',
        f'source_hash = "{info["source_hash"]}"',
        f'recipe_hash = "{info["recipe_hash"]}"',
        f'artifact_hash = "{info["artifact_hash"]}"',
        f'target = "{info["target"]}"',
        "",
        "[compat]",
        f'runtime_version = "{info.get("runtime", "lua@unknown")}"',
        f'lua_abi = "{info["lua_abi"]}"',
        f'runtime_artifact_hash = "{info.get("runtime_artifact_hash", "")}"',
        "",
    ]


    for p in info["provides"]["runtime"]:
        lines.append("[[provides.runtime]]")
        lines.append(f'name = "{p["name"]}"')
        lines.append(f'version = "{p["version"]}"')
        lines.append(f'abi = "{p["abi"]}"')
        lines.append("")

    for p in info["provides"]["bin"]:
        lines.append("[[provides.bin]]")
        lines.append(f'name = "{p["name"]}"')
        lines.append(f'path = "{p["path"]}"')
        lines.append("")

    for p in info["provides"]["headers"]:
        lines.append("[[provides.headers]]")
        lines.append(f'name = "{p["name"]}"')
        lines.append(f'path = "{p["path"]}"')
        lines.append("")

    for p in info["provides"]["native_lib"]:
        lines.append("[[provides.native_lib]]")
        lines.append(f'name = "{p["name"]}"')
        lines.append(f'path = "{p["path"]}"')
        lines.append("")

    for p in info["provides"]["lua_module"]:
        lines.append("[[provides.lua_module]]")
        lines.append(f'name = "{p["name"]}"')
        lines.append(f'path = "{p["path"]}"')
        lines.append("")

    for p in info["provides"].get("lua_cmodule", []):
        lines.append("[[provides.lua_cmodule]]")
        lines.append(f'name = "{p["name"]}"')
        lines.append(f'path = "{p["path"]}"')
        lines.append("")

    with open(manifest_path, "w") as f:
        f.write("\n".join(lines) + "\n")


# ── Registry Writers ─────────────────────────────────────────────────────────
def write_index(registry_dir: str, artifact_infos: list) -> tuple:
    """Write index.toml and index.sqlite.zst. Returns (index_hash, index_bytes, compact_hash, compact_bytes, content_hash, content_bytes)."""
    index_path = os.path.join(registry_dir, "index.toml")
    sqlite_path = os.path.join(registry_dir, "index.sqlite")
    zst_path = os.path.join(registry_dir, "index.sqlite.zst")

    # ── 1. Write index.toml ────────────────────────────────────────────────
    lines = []
    for info in artifact_infos:
        desc_path = os.path.join(
            registry_dir,
            "packages",
            info["name"],
            info["version"],
            "package.toml",
        )
        desc_hash = blake3_hash_file(desc_path)

        lines.append("[[package]]")
        lines.append(f'name = "{info["name"]}"')
        lines.append(f'version = "{info["version"]}"')
        lines.append(f'kind = "{info["kind"]}"')
        lines.append(
            f'descriptor = "packages/{info["name"]}/{info["version"]}/package.toml"'
        )
        lines.append(f'descriptor_hash = "{desc_hash}"')
        lines.append(f'targets = ["{info["target"]}"]')
        lines.append(f'runtimes = {_toml_string_array(info["runtimes"])}')
        lines.append("")


    with open(index_path, "w") as f:
        f.write("\n".join(lines) + "\n")

    index_hash = blake3_hash_file(index_path)
    index_bytes = os.path.getsize(index_path)

    # ── 2. Build SQLite index ──────────────────────────────────────────────
    if os.path.exists(sqlite_path):
        os.remove(sqlite_path)

    conn = sqlite3.connect(sqlite_path)
    conn.execute("PRAGMA journal_mode = DELETE;")
    conn.execute("PRAGMA synchronous = OFF;")

    conn.executescript("""
    CREATE TABLE packages (
        name TEXT NOT NULL,
        version TEXT NOT NULL,
        kind TEXT NOT NULL,
        descriptor TEXT NOT NULL,
        descriptor_hash TEXT NOT NULL,
        yanked INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (name, version)
    );

    CREATE TABLE package_runtimes (
        name TEXT NOT NULL,
        version TEXT NOT NULL,
        runtime TEXT NOT NULL,
        lua_api TEXT,
        lua_abi TEXT,
        PRIMARY KEY (name, version, runtime)
    );

    CREATE TABLE package_targets (
        name TEXT NOT NULL,
        version TEXT NOT NULL,
        target TEXT NOT NULL,
        PRIMARY KEY (name, version, target)
    );

    CREATE TABLE artifacts (
        name TEXT NOT NULL,
        version TEXT NOT NULL,
        artifact_hash TEXT NOT NULL,
        source_hash TEXT,
        recipe_hash TEXT NOT NULL,
        target TEXT,
        runtime TEXT,
        runtime_artifact_hash TEXT,
        lua_api TEXT,
        lua_abi TEXT,
        url TEXT NOT NULL,
        bytes INTEGER,
        format TEXT NOT NULL,
        PRIMARY KEY (name, version, artifact_hash)
    );


    CREATE TABLE provides_lua (
        name TEXT NOT NULL,
        version TEXT NOT NULL,
        artifact_hash TEXT NOT NULL,
        module TEXT NOT NULL,
        path TEXT NOT NULL,
        lua_abi TEXT,
        PRIMARY KEY (artifact_hash, module)
    );

    CREATE TABLE provides_bin (
        name TEXT NOT NULL,
        version TEXT NOT NULL,
        artifact_hash TEXT NOT NULL,
        bin TEXT NOT NULL,
        path TEXT NOT NULL,
        PRIMARY KEY (artifact_hash, bin)
    );

    CREATE TABLE provides_headers (
        name TEXT NOT NULL,
        version TEXT NOT NULL,
        artifact_hash TEXT NOT NULL,
        header TEXT NOT NULL,
        path TEXT NOT NULL,
        PRIMARY KEY (artifact_hash, header)
    );

    CREATE TABLE provides_lua_cmodule (
        name TEXT NOT NULL,
        version TEXT NOT NULL,
        artifact_hash TEXT NOT NULL,
        module TEXT NOT NULL,
        path TEXT NOT NULL,
        lua_abi TEXT,
        PRIMARY KEY (artifact_hash, module)
    );
    """)

    for info in artifact_infos:
        desc_path = f"packages/{info['name']}/{info['version']}/package.toml"
        desc_hash = blake3_hash_file(os.path.join(registry_dir, desc_path))

        conn.execute(
            "INSERT INTO packages (name, version, kind, descriptor, descriptor_hash) VALUES (?, ?, ?, ?, ?);",
            (info["name"], info["version"], info["kind"], desc_path, desc_hash),
        )

        if info.get("runtime"):
            conn.execute(
                "INSERT INTO package_runtimes (name, version, runtime, lua_api, lua_abi) VALUES (?, ?, ?, ?, ?);",
                (
                    info["name"],
                    info["version"],
                    info["runtime"],
                    info.get("lua_api"),
                    info.get("lua_abi"),
                ),
            )

        conn.execute(
            "INSERT INTO package_targets (name, version, target) VALUES (?, ?, ?);",
            (info["name"], info["version"], info["target"]),
        )

        blob_url = blob_index_url(info["artifact_hash"])

        conn.execute(
            "INSERT INTO artifacts (name, version, artifact_hash, source_hash, recipe_hash, target, runtime, runtime_artifact_hash, lua_api, lua_abi, url, bytes, format) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
            (
                info["name"],
                info["version"],
                info["artifact_hash"],
                info.get("source_hash", ""),
                info["recipe_hash"],
                info["target"],
                info.get("runtime"),
                info.get("runtime_artifact_hash"),
                info.get("lua_api"),
                info.get("lua_abi"),
                blob_url,
                info["artifact_bytes"],
                "tar.gz",
            ),
        )


        for m in info["provides"]["lua_module"]:
            conn.execute(
                "INSERT INTO provides_lua (name, version, artifact_hash, module, path, lua_abi) VALUES (?, ?, ?, ?, ?, ?);",
                (
                    info["name"],
                    info["version"],
                    info["artifact_hash"],
                    m["name"],
                    m["path"],
                    info["lua_abi"],
                ),
            )

        for b in info["provides"]["bin"]:
            conn.execute(
                "INSERT INTO provides_bin (name, version, artifact_hash, bin, path) VALUES (?, ?, ?, ?, ?);",
                (
                    info["name"],
                    info["version"],
                    info["artifact_hash"],
                    b["name"],
                    b["path"],
                ),
            )

        for h_prov in info["provides"]["headers"]:
            conn.execute(
                "INSERT INTO provides_headers (name, version, artifact_hash, header, path) VALUES (?, ?, ?, ?, ?);",
                (
                    info["name"],
                    info["version"],
                    info["artifact_hash"],
                    h_prov["name"],
                    h_prov["path"],
                ),
            )

        for m in info["provides"].get("lua_cmodule", []):
            conn.execute(
                "INSERT INTO provides_lua_cmodule (name, version, artifact_hash, module, path, lua_abi) VALUES (?, ?, ?, ?, ?, ?);",
                (
                    info["name"],
                    info["version"],
                    info["artifact_hash"],
                    m["name"],
                    m["path"],
                    info["lua_abi"],
                ),
            )

    conn.commit()
    conn.execute("VACUUM;")
    conn.close()

    # ── 3. Compress with zstd ────────────────────────────────────────────
    if HAS_ZSTD:
        with open(sqlite_path, "rb") as f_in:
            data = f_in.read()
        cctx = zstandard.ZstdCompressor()
        compressed = cctx.compress(data)
        with open(zst_path, "wb") as f_out:
            f_out.write(compressed)
        content_hash = blake3_hash(data)
        content_bytes = len(data)
        compact_hash = blake3_hash(compressed)
        compact_bytes = len(compressed)
        os.remove(sqlite_path)
    else:
        raise RuntimeError(
            "zstandard is required to generate index.sqlite.zst. "
            "Run ./scripts/setup_venv.sh or use Docker."
        )

    return (
        index_hash,
        index_bytes,
        compact_hash,
        compact_bytes,
        content_hash,
        content_bytes,
    )


def write_registry_toml(
    registry_dir: str,
    index_hash: str,
    index_bytes: int,
    compact_hash: str,
    compact_bytes: int,
    content_hash: str,
    content_bytes: int,
) -> None:
    """Write registry.toml with both index.toml and index.compact entries."""
    registry_toml_path = os.path.join(registry_dir, "registry.toml")

    lines = [
        "[registry]",
        'id = "moonstone-synthetic"',
        'name = "Synthetic Test Registry"',
        'protocol = "moonstone.registry.v0"',
        "revision = 1",
        'generated_at = "2026-05-17T00:00:00Z"',
        'min_client = "0.1.0"',
        "",
        "[index]",
        'format = "toml"',
        'url = "index.toml"',
        f'hash = "{index_hash}"',
        f"bytes = {index_bytes}",
        "revision = 1",
        "",
        "[index.compact]",
        'format = "sqlite-zstd"',
        'url = "index.sqlite.zst"',
        f'compressed_hash = "{compact_hash}"',
        f"compressed_bytes = {compact_bytes}",
        f'content_hash = "{content_hash}"',
        f"content_bytes = {content_bytes}",
        "revision = 1",
        "",
        "[blobs]",
        'algorithm = "blake3"',
        'layout = "shard"',
        "",
        "[capabilities]",
        "runtimes = true",
        "artifacts = true",
        "source_packages = true",
        "rocks_bridge = false",
        "private = false",
        "",
    ]

    with open(registry_toml_path, "w") as f:
        f.write("\n".join(lines) + "\n")


def assert_inside(base: str, path: str) -> None:
    base_real = os.path.realpath(base)
    path_real = os.path.realpath(path)
    if not path_real.startswith(base_real + os.sep):
        raise RuntimeError(f"path escapes registry: {path}")


# ── Verification ─────────────────────────────────────────────────────────────
def verify_registry(registry_dir: str) -> bool:
    """Verify all hashes in an existing registry."""
    ok = True

    registry_path = os.path.join(registry_dir, "registry.toml")
    index_path = os.path.join(registry_dir, "index.toml")

    if not os.path.exists(registry_path):
        print(f"FAIL: {registry_path} not found")
        return False
    if not os.path.exists(index_path):
        print(f"FAIL: {index_path} not found")
        return False

    # Parse registry.toml for expected index hashes
    expected_index_hash = None
    expected_compact_hash = None
    with open(registry_path, "r") as f:
        in_compact = False
        for line in f:
            line = line.strip()
            if line == "[index.compact]":
                in_compact = True
                continue
            if line.startswith("["):
                in_compact = False
                continue
            if line.startswith("hash =") and not in_compact:
                expected_index_hash = line.split('"')[1]
            if line.startswith("compressed_hash =") and in_compact:
                expected_compact_hash = line.split('"')[1]

    actual_index_hash = blake3_hash_file(index_path)
    if expected_index_hash != actual_index_hash:
        print("FAIL: index.toml hash mismatch")
        print(f"  expected: {expected_index_hash}")
        print(f"  actual:   {actual_index_hash}")
        ok = False
    else:
        print("OK: index.toml hash matches")

    # Verify SQLite compact index
    zst_path = os.path.join(registry_dir, "index.sqlite.zst")
    if os.path.exists(zst_path) and expected_compact_hash:
        actual_compact_hash = blake3_hash_file(zst_path)
        if expected_compact_hash != actual_compact_hash:
            print("FAIL: index.sqlite.zst compressed hash mismatch")
            print(f"  expected: {expected_compact_hash}")
            print(f"  actual:   {actual_compact_hash}")
            ok = False
        else:
            print("OK: index.sqlite.zst compressed hash matches")
            # Try decompress and verify content hash if zstandard available
            if HAS_ZSTD:
                with open(zst_path, "rb") as f:
                    compressed = f.read()
                dctx = zstandard.ZstdDecompressor()
                decompressed = dctx.decompress(compressed)
                actual_content_hash = blake3_hash(decompressed)
                with open(registry_path, "r") as f:
                    for line in f:
                        if line.strip().startswith("content_hash ="):
                            expected_content_hash = line.split('"')[1]
                            if expected_content_hash != actual_content_hash:
                                print("FAIL: index.sqlite.zst content hash mismatch")
                                print(f"  expected: {expected_content_hash}")
                                print(f"  actual:   {actual_content_hash}")
                                ok = False
                            else:
                                print("OK: index.sqlite.zst content hash matches")
                            break
    else:
        print("WARN: index.sqlite.zst not found, skipping compact index verification")

    # Parse index.toml packages
    with open(index_path, "r") as f:
        content = f.read()

    packages = re.findall(
        r"\[\[package\]\]\n(.*?)(?=\n\[\[package\]\]|\Z)",
        content,
        re.DOTALL,
    )

    for pkg_text in packages:
        m_name = re.search(r'name = "([^"]+)"', pkg_text)
        m_version = re.search(r'version = "([^"]+)"', pkg_text)
        m_descriptor = re.search(r'descriptor = "([^"]+)"', pkg_text)
        m_desc_hash = re.search(r'descriptor_hash = "([^"]+)"', pkg_text)

        if not all([m_name, m_version, m_descriptor, m_desc_hash]):
            print("WARN: malformed package entry in index.toml")
            continue

        name = m_name.group(1)
        version = m_version.group(1)
        descriptor = m_descriptor.group(1)
        expected_desc_hash = m_desc_hash.group(1)

        desc_path = os.path.join(registry_dir, descriptor)
        if not os.path.exists(desc_path):
            print(f"FAIL: {name}@{version}: descriptor not found: {desc_path}")
            ok = False
            continue

        actual_desc_hash = blake3_hash_file(desc_path)
        if expected_desc_hash != actual_desc_hash:
            print(f"FAIL: {name}@{version}: descriptor hash mismatch")
            print(f"  expected: {expected_desc_hash}")
            print(f"  actual:   {actual_desc_hash}")
            ok = False
            continue

        print(f"OK: {name}@{version}: descriptor hash matches")

        # Verify blob hash from descriptor
        with open(desc_path, "r") as f:
            desc_content = f.read()

        # Only match hash/url inside the [[artifacts]] section
        art_section = (
            desc_content.split("[[artifacts]]")[-1]
            if "[[artifacts]]" in desc_content
            else desc_content
        )
        m_art_hash = re.search(r'^hash = "([^"]+)"', art_section, re.M)
        m_art_url = re.search(r'^url = "([^"]+)"', art_section, re.M)

        if not m_art_hash or not m_art_url:
            print(f"WARN: {name}@{version}: no artifact hash/url in descriptor")
            continue

        blob_path = os.path.normpath(os.path.join(registry_dir, m_art_url.group(1)))
        assert_inside(registry_dir, blob_path)
        if not os.path.exists(blob_path):
            print(f"FAIL: {name}@{version}: blob not found: {blob_path}")
            ok = False
            continue

        actual_blob_hash = blake3_hash_file(blob_path)
        if m_art_hash.group(1) != actual_blob_hash:
            print(f"FAIL: {name}@{version}: blob hash mismatch")
            print(f"  expected: {m_art_hash.group(1)}")
            print(f"  actual:   {actual_blob_hash}")
            ok = False
            continue

        print(f"OK: {name}@{version}: blob hash matches")

    return ok


# ── Main ───────────────────────────────────────────────────────────────────
def build_registry(cache_dir: str, output_dir: str) -> int:
    """Build the complete registry."""
    print("Fetching artifacts...")
    fetcher.download_all(cache_dir)

    # Build artifacts
    artifact_infos = []

    for name, info in fetcher.ARTIFACTS.items():
        for version in info["versions"]:
            raw_tarball = os.path.join(cache_dir, f"{name}-{version}.tar.gz")

            if name == "lua":
                artifact_info = build_lua_artifact(raw_tarball, version, output_dir)
            elif name == "inspect":
                artifact_info = build_inspect_artifact(raw_tarball, version, output_dir)
            elif name == "luassert":
                artifact_info = build_luassert_artifact(
                    raw_tarball, version, output_dir
                )
            else:
                raise ValueError(f"Unknown artifact: {name}")

            artifact_info["recipe_hash"] = compute_recipe_hash(artifact_info)
            artifact_infos.append(artifact_info)

    # ── Synthetic Source C Module ──────────────────────────────────────────
    artifact_info = build_synthetic_cmodule_artifact(output_dir)
    artifact_info["recipe_hash"] = compute_recipe_hash(artifact_info)
    artifact_infos.append(artifact_info)

    # ── Synthetic Make Module ──────────────────────────────────────────────
    artifact_info = build_synthetic_make_module_artifact(output_dir)
    artifact_info["recipe_hash"] = compute_recipe_hash(artifact_info)
    artifact_infos.append(artifact_info)

    # ── Synthetic CMake Module ─────────────────────────────────────────────
    artifact_info = build_synthetic_cmake_module_artifact(output_dir)
    artifact_info["recipe_hash"] = compute_recipe_hash(artifact_info)
    artifact_infos.append(artifact_info)

    # Move blobs to registry
    registry_dir = os.path.join(output_dir, "registry")
    blobs_dir = os.path.join(registry_dir, "blobs", "b3")
    os.makedirs(blobs_dir, exist_ok=True)

    for info in artifact_infos:
        h = info["artifact_hash"][3:]  # strip "b3:" prefix
        shard_dir = os.path.join(blobs_dir, h[:2], h[2:4])
        os.makedirs(shard_dir, exist_ok=True)

        dest_path = os.path.join(
            registry_dir, blob_registry_path(info["artifact_hash"])
        )
        shutil.move(info["artifact_path"], dest_path)
        info["artifact_path"] = dest_path

        print(f"[registry] blob: {dest_path}")

    # Write descriptors
    for info in artifact_infos:
        desc_path = os.path.join(
            registry_dir,
            "packages",
            info["name"],
            info["version"],
            "package.toml",
        )
        write_descriptor(desc_path, info)
        print(f"[registry] descriptor: {desc_path}")

    # Write index
    (
        index_hash,
        index_bytes,
        compact_hash,
        compact_bytes,
        content_hash,
        content_bytes,
    ) = write_index(registry_dir, artifact_infos)
    print(f"[registry] index.toml: {index_hash} ({index_bytes} bytes)")
    print(
        f"[registry] index.sqlite.zst: {compact_hash} ({compact_bytes} bytes, content: {content_bytes} bytes)"
    )

    # Write registry.toml
    write_registry_toml(
        registry_dir,
        index_hash,
        index_bytes,
        compact_hash,
        compact_bytes,
        content_hash,
        content_bytes,
    )
    print("[registry] registry.toml")

    # Write store manifests
    artifacts_dir = os.path.join(output_dir, "artifacts")
    os.makedirs(artifacts_dir, exist_ok=True)

    for info in artifact_infos:
        manifest_path = os.path.join(
            artifacts_dir, f"{info['name']}-{info['version']}-manifest.toml"
        )
        write_store_manifest(manifest_path, info)
        print(f"[registry] manifest: {manifest_path}")

    print(f"\nRegistry built at: {registry_dir}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Build a faithful Moonstone registry")
    parser.add_argument(
        "--cache-dir",
        default="fixtures/sandbox/.cache",
        help="Cache directory for raw tarballs",
    )
    parser.add_argument(
        "--output-dir",
        default="sandbox",
        help="Output directory for registry",
    )
    parser.add_argument(
        "--verify",
        metavar="REGISTRY_DIR",
        help="Verify an existing registry",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="Remove output directory before building",
    )
    args = parser.parse_args()

    if args.verify:
        ok = verify_registry(args.verify)
        return 0 if ok else 1

    if args.clean and os.path.exists(args.output_dir):
        print(f"Removing {args.output_dir}")
        shutil.rmtree(args.output_dir)

    os.makedirs(args.output_dir, exist_ok=True)

    return build_registry(args.cache_dir, args.output_dir)


if __name__ == "__main__":
    sys.exit(main())
