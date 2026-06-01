# Moonstone: Technical Feats & Architecture

Moonstone is a next-generation Lua version manager and package environment powered by Zig. It brings modern tooling primitives—common in ecosystems like Rust (Cargo) and Node (npm/pnpm)—to the Lua ecosystem.

Here is a comprehensive breakdown of its core technical achievements and architectural decisions.

## 1. Advanced Dependency Resolution (PubGrub)
Moonstone implements the **PubGrub algorithm**, a state-of-the-art version solving algorithm popularized by Dart's `pub` and Rust's `cargo`.
- **Conflict Explanation:** Unlike older solvers that simply fail or backtrack infinitely, PubGrub tracks the origins of incompatibilities. When a resolution fails, Moonstone provides a human-readable chain of dependencies explaining *why* the conflict occurred.
- **Constraints & Intervals:** It models version constraints (e.g., `^1.0.0`, `~2.1`) mathematically as bounded intervals, allowing for precise intersections and compatibility checks.
- **Multi-Resolver Support:** The coordinator seamlessly blends dependencies from the official Moonstone registry, legacy LuaRocks (`rocks:`), local paths (`path:`), and live links (`link:`).

## 2. Content-Addressable Storage (CAS) & Immutability
Moonstone abandons the traditional "install everything into `/usr/local`" approach in favor of a robust, global Content-Addressable Store.
- **Global Immutability:** Packages are downloaded, compiled, and hashed. They are stored globally in `~/.local/share/moonstone/data/store/v0/` keyed by their cryptographic hash (e.g., Blake3/SHA256). Once an artifact is in the store, it is immutable.
- **Deduplication:** Multiple projects depending on `dkjson@2.6` share the exact same physical bytes on disk.
- **Fast Project Linking:** Installing dependencies in a project (`moon sync`) does not copy files. Instead, Moonstone rapidly constructs a `.moonstone/env` directory using symbolic links pointing back to the immutable store. This makes project switching and environment generation nearly instantaneous.
- **SQLite Index:** The store metadata is backed by a fast, thread-safe SQLite database (`sqlite3` embedded via Zig), ensuring ACID compliance when tracking artifacts, provisions, and live links.

## 3. Runtime & ABI Management
Moonstone handles Lua's notoriously fragmented ecosystem natively.
- **First-Class Runtimes:** Lua implementations (PUC Lua 5.1-5.4, LuaJIT) are treated as standard packages.
- **Strict ABI Enforcement:** Moonstone tracks the Application Binary Interface (ABI) compatibility natively. If a project switches from `lua@5.4` to `luajit@2.1`, Moonstone knows the ABI changed from `5.4` to `5.1` and will refuse to use dynamically linked C modules compiled for the wrong ABI.
- **Global Shims:** `moon setup` provisions global shims (`lua`, `luac`) that dynamically dispatch commands to the correct runtime version based on the current directory's `moonstone.toml` or the user's global default.

## 4. Concurrency & Pipeline Architecture
Moonstone is built in Zig, taking advantage of its low-level performance and explicit memory management.
- **Execution:** While PubGrub itself is highly optimized but sequential by nature, the surrounding pipeline admits concurrency.
- **I/O & Materialization:** Downloading packages, extracting tarballs, and compiling native C modules (`zig-cc`, `cmake`, LuaRocks builtins) can be heavily parallelized.
- **Thread-Safety:** The embedded SQLite driver is compiled with `-DSQLITE_THREADSAFE=1`, allowing concurrent reads/writes to the global index from different worker threads during aggressive parallel fetches.

## 5. First-Class Developer Experience (DX)
Moonstone prioritizes modern DX, eliminating boilerplate and "magic" environment variables.
- **Live Linking:** `moon link` allows developers to register local library paths. Other projects can consume them via `moon add link:<name>`. Moonstone orchestrates live symlinks directly into the consumer's environment, bypassing the immutable store so live code edits are immediately reflected.
- **LSP Integration:** `moon init` automatically generates a precise `.luarc.json` that configures `lua-language-server`. It correctly ignores internal build artifacts while pointing the LSP directly to the resolved `.moonstone/env/share/lua/...` symlink tree.
- **Command Semantics (`moon run`):** Scripts defined in `moonstone.toml` execute strictly within the project's isolated environment. Moonstone manipulates `PATH`, `LUA_PATH`, and `LUA_CPATH` on the fly, ensuring scripts hit the correct runtime and dependencies without polluting the global shell profile.

## 6. Resilience & Diagnostics
- **`moon doctor`:** A built-in diagnostic tool that performs exhaustive system checks. It verifies the integrity of the SQLite database, checks for dangling symlinks in the local environment, tests network connectivity, and validates shim installations.
- **Lockfile Integrity:** `moonstone.lock` guarantees reproducible builds by pinning exact versions, cryptographic artifact hashes, and ABI targets. If the lockfile drifts from the `moonstone.toml`, Moonstone halts execution to prevent undefined behavior.
- **Graceful Failures:** If a download is interrupted or a compilation fails, the artifact is discarded. The immutable store is only updated upon total success, preventing poisoned cache states.

## 7. The Core Execution Flow
The lifecycle of a mutating command (like `moon sync` or `moon add`) is strictly orchestrated to guarantee determinism and environment safety. The flow operates in four distinct phases:

### Phase 1: Context & Coordination
- **Initialization:** The CLI parses arguments and loads the project's `moonstone.toml` and `.moonstone/moonstone.lock`.
- **Coordinator Boot:** The `Coordinator` initializes the global SQLite `StoreDriver` and connects to all configured registries (e.g., the official `moonstone` registry, `synthetic` registries, and `luarocks` translation proxies).

### Phase 2: Dependency Solving (The Graph Provider)
- **Constraint Gathering:** The `GraphProvider` (which feeds the PubGrub algorithm) reads the project's direct dependencies and constraints.
- **Artifact Discovery:** When asked for a version of a package, the Graph Provider searches in a specific priority order:
  1. The **Local Store** (already downloaded/compiled immutable artifacts).
  2. The **Link Store** (packages registered via `moon link`).
  3. **Remote Registries** (querying HTTP endpoints for `package.toml` or `manifest-5.4.json` descriptors).
- **Solving:** PubGrub evaluates these constraints mathematically, resolving conflicts and settling on a single, perfectly compatible graph of package versions.

### Phase 3: Materialization
- **Artifact Resolution:** With the final versions decided, Moonstone iterates through the solution graph to locate the physical artifacts.
- **Downloading & Compilation:** If a package is missing from the local CAS, Moonstone downloads the source or tarball. If it is a native module, it dispatches to the appropriate materializer (e.g., `zig-cc` for C source files, `cmake` for complex builds, or `luarocks` build types).
- **Store Admission:** Successfully materialized packages are cryptographically hashed and permanently written into the immutable CAS store, and their provisions (binaries, lua modules, C libraries) are indexed in SQLite.

### Phase 4: Environment Linking
- **Project Isolation:** Instead of copying files, the `Linker` creates the isolated `.moonstone/env` directory.
- **Symlink Generation:** It iterates over the materialized hashes and projects exact symlinks from the CAS store into standard UNIX paths inside the environment (`env/bin`, `env/share/lua/5.4`, `env/lib/lua/5.4`).
- **Live Link Injection:** If a package originated from a live link (e.g., `path:` or `link:`), the linker skips the immutable store and symlinks the source code directly into the environment, enabling immediate local development feedback.
- **Lockfile Synchronization:** Finally, the exact resolved graph, including artifact hashes and ABI configurations, is serialized into `moonstone.lock` to guarantee future reproducibility.