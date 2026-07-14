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
moon install --latest             # Install the latest Moonstone CLI release
moon install --version 0.1.1      # Install an exact CLI release
moon setup                        # Configure or repair global shims
moon uninstall --preserve-store   # Remove the CLI while retaining artifacts and index metadata
moon interpreter remove lua@5.4.7 # Remove one unreferenced interpreter artifact
```

`moon interpreter remove` requires `--target <triple>` when multiple target builds match and requires `--force` when the runtime is still selected globally or referenced by projects.

---

## 🗂️ Directory Layout

Moonstone uses a content-addressed storage (CAS) model located in your local data directory:

```
~/.local/share/moonstone/
├── data/
│   ├── store/v0/
│   │   └── b3/                  # BLAKE3 sharded CAS store
│   │       └── <h0h1>/<h2h3>/<full-hash>-<name>-<version>/
│   └── index/v0/
│       └── index.sqlite         # Metadata index database
└── tmp/                         # Temporary materialization area
```

---

## 🧠 Core Architecture

- **`moonstone.toml`**: Describes project intent.
- **`moonstone.lock`**: Freezes dependency resolution.
- **`recipe_hash`**: Identifies the exact materialization plan.
- **`artifact_hash`**: Identifies canonical files.
- **`manifest.toml`**: Describes stored artifact.
- **SQLite index**: Accelerates package lookup.
- **`.moonstone/env`**: Exposes runtimes, libraries, and binaries to the project.

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

