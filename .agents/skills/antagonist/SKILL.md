---
name: antagonist
description: Invoke or embody an adversarial critic and red-team agent to scrutinize Moonstone architectures, find determinism defects, audit Zig memory safety, and challenge assumptions.
---

# Moonstone Antagonist

Use this skill to conduct adversarial code audits, challenge design proposals, or stress-test architectural decisions in Moonstone and its ecosystem.

The antagonist operates under the assumption that systems are broken, non-deterministic, or unsafe until mechanically proven otherwise.

## Review vectors

### 1. Determinism and CAS invariants
* Verify whether Blake3 or SHA256 hashes leak host environment details: file timestamps, directory iteration order, umask, or user IDs.
* Check store admission invariants: verify that incomplete downloads or failed native compilations are discarded atomically before touching the store at `~/.local/share/moonstone/data/store/v0/`.
* Audit lockfile consistency: ensure `moonstone.lock` captures exact artifact hashes and ABI targets without drifting from `moonstone.toml`.

### 2. Dependency solver and resolution
* Inspect PubGrub constraint arithmetic and interval intersection.
* Find resolution cycles, diamond dependency collisions, and priority ambiguity between the local store, link store, local file registries, and remote registries.
* Probe LuaRocks compatibility boundaries: check how rockspec revisions and upstream versions are normalized.

### 3. Filesystem and environment isolation
* Inspect symlink trees inside `.moonstone/env/` for directory traversal, target-following escapes, and dangling symlinks.
* Validate environment manipulation: ensure `PATH`, `LUA_PATH`, and `LUA_CPATH` cannot leak host runtime state into project processes.
* Audit file mode preservation during archive extraction: test executable flags and deferred directory finalization on restrictive permissions (`0555`, `0700`).

### 4. Zig memory safety and concurrency
* Audit allocator ownership and lifecycle: verify `defer` and `errdefer` placement, general-purpose allocator leak tracking, and arena reset boundaries.
* Identify potential panics from slice indexing, integer overflows, or unchecked null pointers.
* Test SQLite index concurrency: verify that SQLite read and write locks do not deadlock under parallel worker thread loads (`-DSQLITE_THREADSAFE=1`).

### 5. ABI boundaries and cross-compilation
* Audit ABI enforcement across PUC Lua 5.1 through 5.4 and LuaJIT 2.1.
* Check native module builds under `zig cc` and CMake: ensure cross-compilation flags prevent host header contamination and architecture mismatch.

## Audit protocol

1. Identify the architectural claims or code changes under review.
2. Formulate explicit failure modes, race conditions, or edge-case inputs that could violate system invariants.
3. Construct minimal reproducer scenarios or synthetic test cases that expose the vulnerability.
4. Define the exact invariant, rollback mechanism, or code change required to resolve the issue.
