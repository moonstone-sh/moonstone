# ⋆⁺₊⋆ ☾⋆⁺₊⋆ moon ⋆⁺₊⋆

> A modern, cross-platform **Lua runtime and package manager** written in [Zig](https://ziglang.org).  
> Moonstone creates deterministic Lua project environments from content-addressed artifacts.

---

## ✨ Features

- 🧩 **Deterministic Environments** — Content-addressed store ensures reproducible project setups.
- ⚙️ **Project-Local Isolation** — `moon sync` creates a localized `.moonstone/env/` for each project.
- 🔗 **Smart Linking** — Symlinks binaries and modules from a global CAS store.
- 🧱 **ABI-Aware** — Built-in detection of Lua ABI compatibility.
- 🧰 **Self-Contained** — Compiled Zig binary with no runtime dependencies.

---

## 🚀 Quick Start

1. **Initialize a project**

```bash
moon init . --name my-app --kind script --interpreter lua@5.4
```

2. **Add dependencies**

```bash
moon add inspect
moon add rocks:lua-cjson      # LuaRocks resolver
moon add path:../my-lib       # Local path resolver
moon add link:my-lib          # Registered link resolver
```

3. **Sync the environment**

```bash
moon sync
```

4. **Run your code**

```bash
moon run dev
# or
moon exec lua src/main.lua
```

---

## 🛠️ CLI Lifecycle

Project environments are synchronized separately from the Moonstone binary:

```bash
moon sync                         # Synchronize the current project environment
moon self install --latest        # Install the latest Moonstone CLI release
moon self install --version 0.3.26 # Install an exact CLI release
moon setup                        # Configure or repair global shims
moon self uninstall              # Remove Moonstone user data, store, and shims
moon interpreter remove lua@5.4.7 # Remove one unreferenced interpreter artifact
```

`moon interpreter remove` requires `--target <triple>` when multiple target builds match and requires `--force` when the runtime is still selected globally or referenced by projects.

---

## 🗂️ Directory Layout

By default, Moonstone adheres to the XDG base directory specifications. You can customize these paths using a global `config.toml` or by defining environment variables:

### Path Overrides & Environment Variables
*   **Configuration**: Overridden by `MOONSTONE_CONFIG` or `MOONSTONE_HOME/config` (Defaults to `~/.config/moonstone/`).
*   **Data**: Overridden by `MOONSTONE_DATA` or `MOONSTONE_HOME/data` (Defaults to `~/.local/share/moonstone/`).
*   **Cache**: Overridden by `MOONSTONE_CACHE` or `MOONSTONE_HOME/cache` (Defaults to `~/.cache/moonstone/`).

Additionally, your configuration directory can house a `config.toml` file to override internal folders (`store`, `cache`, `shims`, and `downloads`) and configure default registry priorities.

### Default File Structure
```
~/.config/moonstone/
└── config.toml                  # Global configuration file

~/.local/share/moonstone/
├── data/
│   ├── store/v0/
│   │   └── b3/                  # BLAKE3 sharded global CAS store
│   │       └── <h0h1>/<h2h3>/<full-hash>-<name>-<version>/
│   │           ├── files/       # Package source and build assets
│   │           └── manifest.toml # Exposes artifact features (bin, cmodule, lib)
│   └── index/v0/
│       └── index.sqlite         # SQLite metadata database (caches index, shims, status)
└── tmp/                         # Temporary materialization area
```

---

## 🧠 Core Architecture

Moonstone relies on several unified concepts to achieve offline-first, deterministic environments:

- **Declarative Manifest (`moonstone.toml`)**: Specifies project metadata, interpreter requirements (PUC Lua or LuaJIT under `[interpreter]`), scripts, and packages declared inside canonical `[[dependencies]]` entries.
- **Dependency Lockfile (`moonstone.lock`)**: Freezes resolution by tracking exact resolved versions, package source hashes, ABI targets, and compiler/materializer recipes.
- **Global CAS (Content-Addressed Store)**: A shared global directory housing read-only package files sharded under `blobs/b3/` by their BLAKE3 hashes.
- **Workspace Symlink Environment (`.moonstone/env/`)**: Local to your project, the `moon sync` command projects symlinks of your exact interpreter version and package files directly from the global CAS, isolating execution.
- **SQLite Registry Index**: Locally caches registry indexes, package descriptors, and shim pathways to accelerate dependency solver lookups and local registry indexing.
- **Stored Artifact Manifest (`manifest.toml`)**: Bundled inside each package artifact in the CAS to define exposed features (like CLI binary names, Lua module entrypoints, or C-modules) for linker projections.

---

## 🧰 Build & System Requirements

- **Zig 0.16.0**
- **POSIX system** (Linux/macOS)
- **Common Tools**: `gcc`, `make`, `cmake`, `tar`, `curl`, `zstd`, `sqlite3`

---

## 🪪 License

Apache 2.0
© 2026 Maximo Angel Verzini Davico

---

## 🌌 About

Moonstone is an experimental Lua ecosystem manager aiming to bring deterministic builds, version pinning, and global-store efficiency to Lua and LuaJIT — powered entirely by Zig.

