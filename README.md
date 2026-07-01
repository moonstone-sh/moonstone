# ⋆⁺₊⋆ ☾⋆⁺₊⋆ moonstone.sh ⋆⁺₊⋆

> A modern, cross-platform **Lua runtime and package manager** written in [Zig](https://ziglang.org).  
> Moonstone v0 creates deterministic Lua project environments from content-addressed artifacts.

---

## ✨ Features

- 🧩 **Deterministic Environments** — Content-addressed store ensures reproducible project setups.
- ⚙️ **Project-Local Isolation** — `moonstone sync` creates a localized `env/` for each project.
- 🔗 **Smart Linking** — Symlinks binaries and modules from a global CAS store.
- 🧱 **ABI-Aware** — Built-in detection of Lua ABI compatibility.
- 🧰 **Self-Contained** — Compiled Zig binary with no runtime dependencies.

---

## 🚀 Quick Start (v0)

1. Initialize a project

```bash
moonstone init --name my-app --kind script
```

1. Add dependencies

```bash
moonstone add inspect
moonstone add lua-cjson
moonstone add stylua --bin

# Explicit resolver prefixes
moonstone add rocks:lua-cjson      # LuaRocks resolver
moonstone add path:../my-lib       # Local path resolver
moonstone add link:my-lib          # Registered link resolver
```

1. Sync and Link

```bash
moonstone sync
```

1. Run your code

```bash
moonstone run start
# or
moonstone exec lua src/main.lua
```

## 🛠️ CLI Lifecycle

Project environments are synchronized separately from the Moonstone binary:

```bash
moon sync                         # Synchronize the current project environment
moon install --latest             # Install the latest Moonstone CLI release
moon install --version 0.1.1      # Install an exact CLI release
moon setup                        # Configure or repair global shims
moon uninstall --preserve-store   # Remove the CLI while retaining artifacts and index metadata
moon interpreter remove lua@5.4.7     # Remove one unreferenced interpreter artifact
```

`moon interpreter remove` requires `--target <triple>` when multiple target builds match
and requires `--force` when the runtime is still selected globally or referenced by projects.

## 📚 Guides

- [LÖVE + Moonstone](docs/LOVE.md) — import a LÖVE runtime, create a game project, run `love .`, and export with Ballad.
- [Global Tools](docs/GLOBAL_TOOLS.md) — install and run ecosystem tools from any directory.
- [Adding a Runtime](docs/ADD-RUNTIME.md) — build or import interpreter artifacts.

## 🗂️ Directory Layout

Moonstone v0 uses a content-addressed storage (CAS) model:

```
~/.moonstone/
├── store/v0/
│   └── b3/ # BLAKE3 sharded CAS store
│       └── <h0h1>/<h2h3>/<full-hash>-<name>-<version>/
├── index/v0/
│   └── index.sqlite # Metadata index
└── tmp/ # Temporary materialization area
```

## 🧠 Core Architecture

- **moonstone.toml**: Describes intent.
- **moonstone.lock**: Freezes resolution.
- **recipe_hash**: Identifies materialization plan.
- **artifact_hash**: Identifies canonical files.
- **manifest.toml**: Describes stored artifact.
- **SQLite index**: Accelerates lookup.
- **.moonstone/env**: Exposes runtime/libs/bins to the project.

## 🧰 Build & System Requirements

- **Zig 0.16.0**
- **POSIX system** (Linux/macOS)
- **Common Tools**: `gcc`, `make`, `cmake`, `tar`, `curl`, `zstd`, `sqlite3`, `b3sum` (for testing scripts)

## 🪪 License

Apache 2.0
© 2026 Maximo Angel Verzini Davico

## 🌌 About

Moonstone is an experimental Lua ecosystem manager aiming to bring deterministic builds, version pinning, and global-store efficiency to Lua and LuaJIT — powered entirely by Zig.

---
