# Architecture Reconnaissance Dossier: Universal Lockfile Realization and Replay

**Date:** 2026-07-21  
**Project:** Moonstone (`moonstone-sh/moonstone`)  
**Status:** ARCHITECTURAL AUDIT & DOSSIER  
**Target File:** `docs/maintenance/universal-realization-architecture-audit-2026-07-21.md`  

---

## Core Question & Answer

> **Core Question:** Can Moonstone evolve toward a model of a frozen resolution graph with target-specific realizations, universal exact-artifact recovery, and materializer-specific source replay without rewriting its existing materialization system?

> **Verified Answer:** **Yes.** Moonstone's underlying Content-Addressed Store (CAS) and SQLite index schema (`artifacts` table in `0001_initial.sql`) already support multi-target indexing keyed by `artifact_hash`. However, Moonstone's current lockfile model (`moonstone.lock`), resolution candidates (`Candidate`), and sync orchestrator (`sync.zig`) currently conflate package resolution with single-target artifact realization. Introducing target-specific realizations and clean-store replay can be achieved incrementally by separating resolution graph domain types from artifact realization domain types.

---

## 1. Executive Summary

A comprehensive, codebase-wide architectural audit of Moonstone was performed to evaluate its current package resolution, locking, materialization, toolchain management, CAS storage, and environment projection subsystems.

### Core Findings

1. **Resolution-Realization Conflation:** The `Candidate` struct (`src/core/resolution/candidate.zig`) and `LockEntry` struct (`src/core/domain/lockfile.zig`) conflate resolution identity (`name`, `version`, `resolver`) with realization state (`artifact_hash`, `local_path`, `target`, `runtime_artifact_hash`).
2. **Origin-Location Overwrite:** `pkg.origin` in `Candidate` uses `.artifact_hash` for candidates loaded from the CAS. This causes `sync.zig:1498` to serialize `resolver = "store"`, obscuring whether the package originated from LuaRocks (`rocks:`) or Moonstone Registry (`moonstone:`).
3. **CAS Storage Flexibility:** The local SQLite index (`artifacts` table) is keyed by `artifact_hash PRIMARY KEY`. It natively stores multiple target artifacts per `(name, version)` tuple without collision.
4. **Subprocess Execution:** Subprocess execution across all materializers (`native_cmodule`, `cmake`, `command`, `builtin`) uses direct `std.process.run` invocations. There is no unified process sandbox or external materializer RPC boundary today.
5. **Toolchain Ambient Dependency:** Compiler discovery (`zig version`, `cmake --version`) inspects the ambient host `PATH` dynamically during build time. Toolchain binary identities are not content-addressed in the lockfile.

---

## 2. Current Package Lifecycle

### Full Call Graph: `moon add rocks:<package>` -> `moon sync`

```text
AddCommand.run (src/cli/commands/add.zig)
  ├── package_spec.parse ("rocks:inspect")
  ├── Coordinator.resolve_and_materialize (src/core/resolution/coordinator.zig)
  │     ├── PackageProvider.get_candidates (src/core/resolution/provider/graph_provider.zig)
  │     │     └── LuaRocksSource.query (src/core/resolution/sources/luarocks.zig)
  │     ├── PubGrub.solve (src/core/resolution/solver/pubgrub.zig)
  │     │     └── Returns solution map of Candidates
  │     ├── Materializer.materialize_remote (src/core/materialization/materializer.zig)
  │     │     ├── Downloads source/rockspec payload
  │     │     ├── computeRecipeHash (src/core/store.zig)
  │     │     ├── Materializers (copy_lua / native_cmodule / cmake)
  │     │     ├── artifact_hash (src/core/identity/hash.zig)
  │     │     └── store.commit_to_store_with_sources (src/core/store.zig)
  │     │           ├── Writes files to ~/.moonstone/store/files/b3/...
  │     │           └── Inserts row into ~/.moonstone/index/index.sqlite
  │     └── Updates moonstone.toml dependencies
  │
  └── SyncCommand.run (src/cli/commands/sync.zig)
        ├── Reads moonstone.toml & moonstone.lock
        ├── Replays lockfile OR invokes PubGrub
        ├── Materializes missing candidates
        ├── RunEnv.get_run_env (src/core/project/run_env.zig)
        │     └── Links .moonstone/env/ lua_path, lua_cpath, and bin/
        └── Serializes updated moonstone.lock
```

*Verification:* `add.zig` and `sync.zig` share `Coordinator` and `Materializer` logic, but `sync.zig` contains duplicated logic for lockfile parsing, candidate mapping, and `moonstone.lock` serialization.

---

## 3. Core Domain Types Inventory

| Type Name | File Location | Primary Domain Purpose | Data Ownership | Portable? | Serialized in Lockfile? | Conflation Notes |
| :--- | :--- | :--- | :---: | :---: | :---: | :--- |
| `Candidate` | `src/core/resolution/candidate.zig:81` | Represents package candidate across resolution and materialization | Owns slices | No | Partial | Conflates solver candidate, source URL, local path, and CAS artifact hash. |
| `Origin` | `src/core/resolution/candidate.zig:5` | Source registry or path origin | Owns slices | Partial | Partial | Combines `.luarocks`, `.moonstone_registry`, `.path`, and `.artifact_hash`. |
| `LockEntry` | `src/core/domain/lockfile.zig:6` | Serialized lockfile entry | Owns slices | Partial | Yes | Flattens resolution, source provenance, recipe, and realization into one table. |
| `Recipe` | `src/core/domain/manifest.zig:515` | Internal build recipe struct | Owns slices | Yes | No | Internal struct passed to `recipe_hash`. |
| `StoreDriver` | `src/core/store/driver.zig:45` | SQLite store & index manager | Holds DB handles | No | No | Manages `~/.moonstone/index/index.sqlite`. |
| `RunEnv` | `src/core/project/run_env.zig:4` | Environment projection state | Owns maps & paths | No | No | Constructs `.moonstone/env/` symlinks/paths. |

---

## 4. Current Resolution Model

- **Package Identity:** A package is identified during resolution by `(name, version)` and `resolver` (`rocks` or `moonstone`).
- **Target Independence:** Resolution via PubGrub (`pubgrub.zig`) operates on version constraints and dependency graphs. PubGrub itself is **target-independent**.
- **Runtime Binding:** Runtime resolution (`moonstone/lua@5.4`) binds the active runtime spec (`lua_abi = "5.4"`) to the resolution graph.
- **Single Active Target Limitation:** Currently, `Candidate` and `LockEntry` carry a single `target` string (e.g. `"native"`). The lockfile cannot represent multiple target realizations for the same resolved package.

---

## 5. Current Lockfile Field Classification

| Lockfile Field | Current Meaning | Correct Domain Layer | Portable Across Machines? | Target-Specific? |
| :--- | :--- | :--- | :---: | :---: |
| `name` | Package name | Resolution | Yes | No |
| `version` | Package SemVer version | Resolution | Yes | No |
| `resolver` | Source resolver | Resolution / Provenance | Yes | No |
| `source_hash` | Raw source archive BLAKE3 | Source Provenance | Yes | No |
| `source_url` | Upstream archive HTTP URL | Source Provenance | Yes | No |
| `rockspec` | Rockspec HTTP URL | Source Provenance | Yes | No |
| `rockspec_hash` | Rockspec BLAKE3 hash | Source Provenance | Yes | No |
| `recipe_hash` | Recipe preimage BLAKE3 hash | Realization | Yes | Yes (includes `target`, `runtime_hash`) |
| `artifact_hash` | Directory tree BLAKE3 hash | Realization | Yes | Yes |
| `target` | Target triple | Realization | Yes | Yes |
| `lua_abi` | Lua ABI version | Realization | Yes | Yes |
| `runtime` | Runtime spec string | Realization | Yes | Yes |
| `reproducible` | Reproducibility flag | Realization | Yes | No |

---

## 6. Hash Semantics & Verification

### `source_hash`
- **Definition:** Verified in code (`luarocks.zig:767` & `materializer.zig:492`) as the **BLAKE3 hash of raw downloaded source archive bytes** (`.tar.gz`, `.zip`, `.src.rock`).

### `recipe_hash`
- **Definition:** Preimage string formatted in `src/core/store.zig:computeRecipeHash`:
  `moonstone:recipe:v2\nkind={kind}\nname={name}\nversion={version}\nsource_hash={source_hash}\nmaterializer={materializer}\nstrategy={strategy}\nzig_version={zig_version}\ncmake_version={cmake_version}\nldflags={ldflags}\nruntime_hash={runtime_hash}\nlua_abi={lua_abi}\ntarget={target}\nsources={sources}\noutput_module={output_module}\noutput_path={output_path}\ncollect={collect}\nbuild_env={build_env}\n`

### `artifact_hash`
- **Definition:** Implemented in `src/core/identity/hash.zig:artifact_hash`.
- Recursively iterates directory entries in lexicographical order.
- Hashes file contents (BLAKE3), symlink targets, and file modes.
- Output format: `"b3:"` followed by 64-character hex string.

---

## 7. Inventory of Supported Materializers

| Materializer Name | Implementation File | Selection Mechanism | Subprocess Tools Used | Network Access? | Determinism Verified? |
| :--- | :--- | :--- | :--- | :---: | :---: |
| **Pure Lua / Builtin** | `materializers/copy_lua.zig` | Default for pure-Lua rocks | `tar`, `cp` | No (uses cached source) | **Yes (100% Bit-for-Bit)** |
| **Native C Module** | `materializers/native_cmodule.zig` | `m.kind == "native_cmodule"` | `zig cc`, `zig version` | No | Toolchain Dependent |
| **CMake** | `materializers/cmake.zig` | `m.kind == "cmake"` | `cmake`, `make` / `ninja` | No | Toolchain Dependent |
| **Custom Command** | `materializers/command.zig` | `m.kind == "command"` | Arbitrary shell commands (`sh -c`) | Maybe | Nondeterministic |
| **Unpack Binary** | `materializers/unpack_binary.zig` | `m.kind == "unpack_binary"` | `tar`, `zstd` | No | Deterministic |

---

## 8. Audit of Pure-Lua Materialization

- **Execution Path:** `materializer.zig` calls `copy_lua.zig` to copy `.lua` source files into `build_out_path`.
- **Determinism Test (Verified by Reproduction):**
  - Run A Hash: `b3:5ac9feaa83ddf51cad9d0f25e20bbf37aede1dd2f5679e5d6f735c62819444bb`
  - Run B Hash: `b3:5ac9feaa83ddf51cad9d0f25e20bbf37aede1dd2f5679e5d6f735c62819444bb`
- **Target Independence:** Pure-Lua `.lua` files are architecture-independent. However, current recipes embed `target` and `runtime_hash` into `recipe_hash`, tying the recipe instance to a specific target host.

---

## 9. Audit of Zig CC Native C-Module Materialization

- **Execution Path:** `materializer.zig` $\rightarrow$ `materializers/native_cmodule.zig`.
- **Process Invocations:**
  1. `zig version` to capture `zig_version` string.
  2. `zig cc -shared -o <module.so> <sources...> -I<lua_incdir> <cflags>`.
- **Untracked Host Dependencies:**
  - Host macOS SDK / sysroot paths (`-isysroot`).
  - Host C compiler headers (`<stdio.h>`, `<stdlib.h>`).
  - Dynamic Zig version installed on host `PATH`.

---

## 10. Audit of CMake Materialization

- **Execution Path:** `materializer.zig` $\rightarrow$ `materializers/cmake.zig`.
- **Process Invocations:**
  1. `cmake --version`
  2. `cmake -B <build_dir> -S <source_dir> -DCMAKE_INSTALL_PREFIX=...`
  3. `cmake --build <build_dir>`
  4. `cmake --install <build_dir>`
- **Untracked Host Dependencies:**
  - System CMake version, system generator (`Unix Makefiles` vs `Ninja`), system C/C++ compiler, host library dependencies detected via `find_package()`.

---

## 11. External Build Ecosystems & Input-Closure Analysis

| Ecosystem | Native Lock File | Required Toolchain | Primary Payload Unit | Current Support in Moonstone |
| :--- | :--- | :--- | :--- | :--- |
| **Rust** | `Cargo.lock` | `rustc`, `cargo` | Crates (`.crate`) | Not supported (invocable via `command`) |
| **Go** | `go.mod`, `go.sum` | `go` | Go modules (`.zip`) | Not supported (invocable via `command`) |
| **Node.js** | `package-lock.json` | `node`, `npm`/`pnpm` | npm tarballs (`.tgz`) | Not supported |
| **C / Make** | `Makefile` | `make`, `gcc`/`clang` | Source archive | Supported via `command` / `luarocks` |

---

## 12. Subprocess & Process Runner Architecture

Subprocess invocation is handled via standard Zig library calls:
- `std.process.run(allocator, io, .{ .argv = &.{ ... } })`
- **Environment Handling:** `Materializer` passes `self.environ_map` down to subprocesses.
- **Sandboxing:** None currently. Subprocesses inherit standard file access and network capabilities.
- **Process Runner Abstraction Seam:** `std.process.run` invocations are scattered across `materializer.zig`, `native_cmodule.zig`, `cmake.zig`, `command.zig`, and `luarocks.zig`.

---

## 13. Tool Identity & Provisioning

- **Lua Runtime:** Managed by Moonstone, stored in CAS (`moonstone/lua@5.4.7`), headers linked into `.moonstone/env/include/`.
- **Zig:** Discovered dynamically from host `PATH` via `zig version`. Not managed by CAS.
- **CMake:** Discovered dynamically from host `PATH` via `cmake --version`. Not managed by CAS.
- **Make / Tar / Cp / Chmod:** Discovered dynamically from host `PATH`.

---

## 14. Target Representation & Multi-Target Feasibility

- **Target Representation:** Lowercase string (e.g. `"native"`, `"aarch64-macos"`, `"x86_64-linux-gnu"`).
- **SQLite Index Multi-Target Feasibility:**
  The `artifacts` table schema:
  `CREATE TABLE artifacts (artifact_hash TEXT PRIMARY KEY, name TEXT, version TEXT, target TEXT, ...);`
  The store natively supports multiple artifacts for the same `(name, version)` across different `target` strings!
- **Lockfile Multi-Target Feasibility:**
  `moonstone.lock` currently flattens packages under `[[package]]`. Supporting multi-target realizations requires structuring realizations under `[[package.realization]]` tables.

---

## 15. Environment Projection

- **File:** `src/core/project/run_env.zig`.
- **Mechanism:** Builds `.moonstone/env/` containing:
  - `bin/`: Executable symlinks / wrapper scripts.
  - `share/lua/5.4/`: Pure-Lua module symlinks.
  - `lib/lua/5.4/`: Native C module (`.so` / `.dylib`) symlinks.
- **Projection Determinism:** Driven entirely by `moonstone.lock` package entries and SQLite artifact lookups.

---

## 16. Multi-Machine Scenario Assessment

### Scenario: Shared `moonstone.lock` between macOS ARM64 & Linux x86_64

| Package Type | Current Behavior on Second Machine | Desired Universal Behavior |
| :--- | :--- | :--- |
| **Pure-Lua (`rocks:inspect`)** | Store miss -> `error.LockedArtifactMissing` | Rematerialize pure-Lua source or reuse portable artifact |
| **Native C (`rocks:lua-cjson`)** | Store miss -> `error.LockedArtifactMissing` | Fetch target-specific artifact (`x86_64-linux`) or rebuild |
| **Runtime (`moonstone/lua@5.4`)** | Resolves host-specific runtime binary | Selects target-specific runtime realization |

---

## 17. Proposed Domain Boundaries

```text
+-----------------------------------------------------------------------+
|                         ResolutionGraph                               |
|   (PackageName, Version, Kind, SourceProvenance, DependencyEdges)     |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                        LockedSourceProvenance                         |
|   (SourceURL, SourceHash, RockspecURL, RockspecHash, MaterializerKind)|
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                         TargetRealization                             |
|   (TargetTriple, LuaABI, RecipeHash, ArtifactHash, RealizerStatus)    |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                       LockedArtifactRealizer                          |
|   (CAS Lookup -> Remote Artifact Fetch -> Source Rematerialization)    |
+-----------------------------------------------------------------------+
```

---

## 18. Answers to Required Questions

### Current Architecture
1. **Does Moonstone separate resolution from realization?** Partially in solver types, but conflated in `Candidate` and `LockEntry`.
2. **Can one package have multiple target realizations?** In SQLite index, yes; in `moonstone.lock`, no.
3. **Does lockfile represent a graph or flattened environment?** A flattened package list.
4. **Is `artifact_hash` tied to target/runtime?** Yes, `target` and `runtime_hash` enter `computeRecipeHash`.
5. **Can source, recipe, and artifact metadata survive a clean machine?** Yes, stored in `moonstone.lock`.

### Existing Materializers
6. **Which materializers are deterministic today?** Pure-Lua (`copy_lua.zig`) and `unpack_binary.zig`.
7. **Which depend on untracked host state?** `native_cmodule` (Zig version/SDK), `cmake` (CMake/generator), `command` (shell).

### Multi-Target Locking
8. **Can one lock preserve resolution across macOS and Linux?** Yes, because PubGrub resolution is target-independent.
9. **Can pure-Lua realizations be shared?** Yes, pure `.lua` source files are platform-agnostic.

---

## 19. Recommended Implementation Slicing

### Phase 1: Core Domain Separation & Locked Realizer Boundary
- Create `src/core/resolution/locked_realizer.zig`.
- Fix `pkg.origin` mapping to preserve `resolver = "rocks"` in `moonstone.lock`.

### Phase 2: Schema v1 & Pure-Lua Clean-Store Replay
- Update `moonstone.lock` to serialize complete `[package.source]` and `[package.recipe]` provenance.
- Implement pure-Lua source rematerialization for `rocks:inspect` on clean store misses.

### Phase 3: Multi-Target Realization Schema & Remote Artifact Proxy
- Update `moonstone.lock` to support target-scoped realizations under `[[package.realization]]`.
- Add remote pre-built artifact proxy retrieval by `artifact_hash`.

---

## 20. Suggested Next Agent Task

> **Next Task:** Implement Phase 1 & Phase 2 — `locked_realizer.zig` domain boundary, origin resolver preservation, and pure-Lua clean-store replay for `rocks:` packages in `moonstone`.
