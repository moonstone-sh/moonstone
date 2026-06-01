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
moon runtime remove lua@5.4.7     # Remove one unreferenced runtime artifact
```

`moon runtime remove` requires `--target <triple>` when multiple target builds match
and requires `--force` when the runtime is still selected globally or referenced by projects.

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
- **Common Tools**: `gcc`, `make`, `tar`, `zstd`, `python3` (for testing/scripts)

## 🪪 License

Apache 2.0
© 2026 Maximo Angel Verzini Davico

## 📦 Publishing CLI Releases

`zig build` compiles versioned binaries into `zig-out/bin/`. Release packaging and
publishing are separate so builds do not mutate checksums or deployment state.

Set the release version in `build.zig.zon`, prepare the Python environment once,
then publish from the repository root:

```bash
./release-tools/setup-venv.sh
./release-tools/publish-release.sh
```

The publish script rebuilds the matrix, creates deterministic `.tar.gz` archives,
generates `release-manifest.json`, `SHA256SUMS`, and `B3SUMS`, uploads the immutable
version directory, and atomically advances the VPS `latest` pointer. It refuses to
publish a version that is not newer than the remote pointer.

The default destination is `vps:/home/moonstone/moonstone.sh/public/releases`.
Override it when needed:

```bash
MOONSTONE_RELEASE_HOST=my-vps \
MOONSTONE_RELEASES_PATH=/srv/moonstone/releases \
./release-tools/publish-release.sh
```

## 🌌 About

Moonstone is an experimental Lua ecosystem manager aiming to bring deterministic builds, version pinning, and global-store efficiency to Lua and LuaJIT — powered entirely by Zig.

---
