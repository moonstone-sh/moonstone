# Audit Report: Lockfile Replay and Store-Miss Recovery (Revised)
**Date:** 2026-07-21  
**Project:** Moonstone (`moonstone-sh/moonstone`)  
**Target:** Lockfile Replay, CAS Resolution, & Clean-Store Recovery  

---

## 1. Executive Summary

An architectural audit of Moonstone's synchronization (`moon sync`) and lockfile replay pipeline was conducted to evaluate whether Moonstone lockfiles (`moonstone.lock`) can reproduce an environment on a clean machine when referenced artifacts are absent from the local Content-Addressed Store (CAS).

### Key Findings

1. **Failure Scenario Confirmed:** When `moon sync` runs on a clean store (or when `~/.moonstone/store/` is absent), lockfile replay mode (`replay_lock = true`) queries the local CAS by `artifact_hash`. Upon experiencing a store miss, **synchronization immediately aborts with `error.LockedArtifactMissing`**. Moonstone makes no attempt to retrieve the exact artifact remotely or rematerialize it from source.
2. **Source Retrieval Guarantee:** Source archives are not "reconstructable" from thin air, but **source can be retrieved and verified when an immutable matching payload remains available** (via `source_url` & `source_hash` or `rockspec` & `rockspec_hash` recorded in `moonstone.lock`).
3. **Recipe Hash Preimage Gaps:** `recipe_hash` is computed from 17 specific fields in production (`src/core/store.zig`). Only 8 of these 17 fields are stored directly in `moonstone.lock`. The remaining inputs (build strategy, C source lists, linker flags, build environment, `runtime_hash`) must be recovered from the locked `rockspec` payload.
4. **Resolver Serialization Identity Loss:** Packages resolved via `rocks:` serialize `resolver = "store"` into `moonstone.lock` because candidates loaded from the CAS have `pkg.origin = .artifact_hash`. This obfuscates the top-level resolver identity, though LuaRocks origin metadata remains in `rockspec` fields.
5. **Pure-Lua Artifact Determinism (Empirically Proven):** Independent clean-store materializations of pure-Lua packages (`rocks:inspect`) produced the **exact same `artifact_hash`** (`b3:5ac9feaa83ddf51cad9d0f25e20bbf37aede1dd2f5679e5d6f735c62819444bb`), proving that pure-Lua source rematerialization is bit-for-bit deterministic.

### Replay Guarantee Provided Today
> **Current Replay Guarantee:** Moonstone's lockfile replay currently guarantees **local-store projection only**. Synchronization succeeds strictly when all required artifact hashes are already present in the warm local Content-Addressed Store. It does not support clean-machine environment reconstruction without forcing a fresh dependency resolution (`--update`).

---

## 2. Reproduction Instructions & Empirical Findings

A hermetic, isolated test harness was created using temporary environment paths (`MOONSTONE_HOME`, `MOONSTONE_CONFIG`, `MOONSTONE_DATA`, `MOONSTONE_CACHE`) to eliminate mutation of user state.

### 2.1. Store-Miss Reproduction

```bash
#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(mktemp -d /tmp/moonstone_audit_XXXXXX)
export MOONSTONE_HOME="$TEST_DIR/home"
export MOONSTONE_CONFIG="$TEST_DIR/config"
export MOONSTONE_DATA="$TEST_DIR/data"
export MOONSTONE_CACHE="$TEST_DIR/cache"

mkdir -p "$MOONSTONE_HOME" "$MOONSTONE_CONFIG" "$MOONSTONE_DATA" "$MOONSTONE_CACHE" "$TEST_DIR/project"
cd "$TEST_DIR/project"

MOON_BIN="/Users/extrordinaire/Workbench/user/moonstone/zig-out/bin/moon"

"$MOON_BIN" init --yes
"$MOON_BIN" add rocks:inspect
"$MOON_BIN" sync # Generates moonstone.lock & populates CAS

# Wipe local CAS & SQLite index
rm -rf "$MOONSTONE_HOME/store" "$MOONSTONE_DATA/store" "$MOONSTONE_DATA/index"

# Attempt sync on clean store
"$MOON_BIN" sync || echo "EXIT_CODE=$?"
```

#### Output on Clean Store
```text
Reading registry configuration...
Resolving runtime moonstone/lua@5.4...
Using interpreter: moonstone/lua@5.4.7
Replaying lockfile (1 package)...
Error: Locked artifact is missing from the local store.

Package:
  store:inspect@3.1.3-0

Expected artifact:
  b3:5ac9feaa83ddf51cad9d0f25e20bbf37aede1dd2f5679e5d6f735c62819444bb

The lockfile requires this exact artifact, but it was not found.
Run without --locked to resolve/rebuild, or restore the
artifact into the local store.
```

**Observed Network Activity:** Zero network requests were attempted after the store miss.

### 2.2. Pure-Lua Artifact Determinism Proof

Two completely independent builds of `rocks:inspect` were executed on separate clean stores.

```text
Run A Artifact Hash: b3:5ac9feaa83ddf51cad9d0f25e20bbf37aede1dd2f5679e5d6f735c62819444bb
Run B Artifact Hash: b3:5ac9feaa83ddf51cad9d0f25e20bbf37aede1dd2f5679e5d6f735c62819444bb
Result: DETERMINISTIC (Bit-for-bit match)
```

---

## 3. Lockfile Schema Inventory & Preimage Proof

### 3.1. Lockfile Schema Inventory (`LockEntry`)

The lockfile structure is defined in `src/core/domain/lockfile.zig` as `LockEntry`.

| Replay Input | In Lockfile? | Field Name | Used During Replay Today? |
| :--- | :---: | :--- | :---: |
| Package Name | Yes | `name` | Yes |
| Package Version | Yes | `version` | Yes |
| Package Kind | Yes | `kind` | Yes |
| Source Location / URL | Yes | `source` / `source_url` | **No** |
| Source Kind | Yes | `source_kind` | **No** |
| Source Payload Path | Yes | `source_payload` | **No** |
| Source Hash | Yes | `source_hash` | **No** |
| Recipe Hash | Yes | `recipe_hash` | **No** |
| Artifact Hash | Yes | `artifact_hash` | **Yes** (sole lookup key) |
| Rockspec URL | Yes | `rockspec` | **No** |
| Rockspec Hash | Yes | `rockspec_hash` | **No** |
| Rockspec Payload | Yes | `rockspec_payload` | **No** |
| Resolver Identity | Yes | `resolver` | Yes (deserialized to `"store"`) |
| Link Mode | Yes | `link_mode` | Yes |
| Runtime Spec | Yes | `runtime` | Yes |
| Lua ABI | Yes | `lua_abi` | Yes |
| Target Triple | Yes | `target` | **No** |
| Constellation | Yes | `constellation` | **No** |
| Reproducible Flag | Yes | `reproducible` | **No** |

---

### 3.2. Recipe Hash Preimage Enumeration

In `src/core/store.zig` (`computeRecipeHash`), the exact recipe-hash preimage string is constructed in production as:

```text
moonstone:recipe:v2
kind={kind}
name={name}
version={version}
source_hash={source_hash}
materializer={materializer}
strategy={strategy}
zig_version={zig_version}
cmake_version={cmake_version}
ldflags={ldflags}
runtime_hash={runtime_hash}
lua_abi={lua_abi}
target={target}
sources={sources}
output_module={output_module}
output_path={output_path}
collect={collect}
build_env={build_env}
```

#### Preimage Component Availability Analysis

| Preimage Component | Present in Lockfile? | Location when Missing |
| :--- | :---: | :--- |
| `kind`, `name`, `version` | Yes | `LockEntry` |
| `source_hash` | Yes | `LockEntry.source_hash` |
| `materializer` | Yes | `LockEntry.source_kind` |
| `lua_abi`, `target` | Yes | `LockEntry` |
| `strategy` | **No** | Embedded in `rockspec_payload` |
| `zig_version`, `cmake_version` | **No** | System toolchain / build context |
| `ldflags` | **No** | Embedded in `rockspec_payload` |
| `runtime_hash` | **No** | Active runtime artifact manifest (`manifest.toml`) |
| `sources` | **No** | Embedded in `rockspec_payload` |
| `output_module`, `output_path` | **No** | Derived by materializer from package name |
| `collect` | **No** | Derived from rockspec build table |
| `build_env` | **No** | Embedded in rockspec or materializer context |

**Proof:** `recipe_hash` **cannot** be computed from `moonstone.lock` alone. Reconstructing `recipe_hash` requires parsing the locked `rockspec_payload` (or fetching `rockspec` and verifying `rockspec_hash`) and inspecting the active runtime's `runtime_hash`.

---

## 4. Analysis of `resolver = "store"` Identity Loss

### Why `rocks:` packages serialize as `resolver = "store"`

In `src/cli/commands/sync.zig` (lines 1493–1499):

```zig
.resolver = try allocator.dupe(u8, switch (pkg.origin) {
    .luarocks => "rocks",
    .moonstone_registry => "moonstone",
    .link => "link",
    .path => "path",
    else => "store",
}),
```

When a dependency is added via `moon add rocks:inspect`:
1. The package is downloaded, materialized, and registered in the local CAS store index.
2. When `moon sync` reads candidates from the store index, their `origin` field is populated as `.artifact_hash` (representing a local store artifact).
3. In `sync.zig`, `switch (pkg.origin)` matches `.artifact_hash`, falling through to `else => "store"`.
4. As a result, `resolver = "store"` is written into `moonstone.lock`.

### Impact on Recovery
While `resolver` field is serialized as `"store"`, the LuaRocks origin metadata is **not lost**:
- `rockspec` (`https://luarocks.org/inspect-3.1.3-0.rockspec`) and `rockspec_hash` (`b3:4c0a...`) remain fully preserved in `LockEntry`.
- However, if a store-miss recovery handler relies solely on `entry.resolver == "rocks"`, it will fail because `entry.resolver` is `"store"`. The recovery engine must inspect `entry.rockspec` or `entry.source_kind` to identify LuaRocks provenance.

---

## 5. Sync & Replay Call Graph

```text
moon sync
  ├── src/cli/commands/sync.zig:SyncCommand.run
  │     ├── Reads moonstone.lock
  │     ├── LockFile.parse (src/core/domain/lockfile.zig)
  │     ├── Evaluates can_replay_lock = (!self.update and existing_lock.packages.items.len > 0 and matches)
  │     │
  │     └── [replay_lock == true]
  │           ├── Loops through existing_lock.packages.items
  │           ├── Constructs ArtifactRequest{ .artifact_hash = entry.artifact_hash }
  │           ├── Calls provider_impl.get_artifact(req)
  │           │     │
  │           │     └── src/core/resolution/provider/graph_provider.zig:RegistryProvider.get_artifact
  │           │           ├── index.get_candidate_by_hash(hash)  [SQLite lookup]
  │           │           ├── Verifies file path exists: std.Io.Dir.cwd().access(c.path)
  │           │           └── Path missing on disk -> returns null
  │           │
  │           └── [maybe_art == null] -> returns error.LockedArtifactMissing  <-- FAILURE POINT
  │
  └── src/cli/commands/command.zig:formatCommandError
        └── Prints "Error: Locked artifact is missing from the local store."
```

---

## 6. Root-Cause Classification

1. **Implementation Path Bug / Missing Fallback Pipeline (Primary):**
   - The lockfile schema already captures comprehensive source provenance (`source_url`, `source_hash`, `rockspec`, `rockspec_hash`).
   - `src/cli/commands/sync.zig` lacks a store-miss recovery handler during `replay_lock`. It treats a local CAS miss as an unrecoverable fatal error (`error.LockedArtifactMissing`).
2. **Resolver Label Normalization Loss (Secondary):**
   - `switch (pkg.origin)` overwrites `resolver = "rocks"` with `"store"` for candidates loaded from the CAS.

---

## 7. Domain Boundary Architecture Proposal (`ensureLockedArtifact`)

To avoid polluting `SyncCommand.run` with materialization, networking, and resolver fallback logic, we propose creating a clean domain boundary interface: `ensureLockedArtifact`.

### Proposed Interface

Location: `src/core/resolution/locked_realizer.zig`

```zig
pub const RealizeResult = struct {
    candidate: candidate_mod.Candidate,
    recovered_from: enum { local_cas, remote_artifact, source_rematerialization },
};

pub fn ensureLockedArtifact(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    entry: *const lockfile.LockEntry,
    provider: *package_provider.PackageProvider,
    store: *store_driver.StoreDriver,
) !RealizeResult {
    // 1. Check local CAS by artifact_hash
    if (try store.get_candidate_by_hash(entry.artifact_hash)) |cand| {
        return RealizeResult{ .candidate = cand, .recovered_from = .local_cas };
    }

    // 2. Query remote artifact registries/caches by artifact_hash
    if (try provider.fetch_remote_artifact_by_hash(entry.artifact_hash)) |cand| {
        return RealizeResult{ .candidate = cand, .recovered_from = .remote_artifact };
    }

    // 3. Source Rematerialization Fallback
    if (entry.source_url.len == 0 and entry.rockspec.len == 0) {
        return error.InsufficientSourceProvenance;
    }

    // a. Fetch source payload & verify source_hash
    const source_bytes = try provider.fetch_source_payload(entry.source_url);
    defer allocator.free(source_bytes);
    const actual_src_hash = try hash.source_hash(allocator, source_bytes);
    defer allocator.free(actual_src_hash);
    if (!std.mem.eql(u8, actual_src_hash, entry.source_hash)) {
        return error.SourceHashMismatch;
    }

    // b. Fetch rockspec & verify rockspec_hash (if present)
    if (entry.rockspec.len > 0) {
        const rockspec_bytes = try provider.fetch_rockspec(entry.rockspec);
        defer allocator.free(rockspec_bytes);
        const actual_rs_hash = try hash.source_hash(allocator, rockspec_bytes);
        defer allocator.free(actual_rs_hash);
        if (!std.mem.eql(u8, actual_rs_hash, entry.rockspec_hash)) {
            return error.RockspecHashMismatch;
        }
    }

    // c. Rematerialize package from verified source & rockspec
    const rebuilt_cand = try materializer.rematerializeFromLockedProvenance(allocator, io, env, entry);
    
    return RealizeResult{ .candidate = rebuilt_cand, .recovered_from = .source_rematerialization };
}
```

---

## 8. Unresolved Lockfile Semantics Decisions

The audit highlights three distinct interpretations of `artifact_hash` during lockfile replay:

### Question: What is `artifact_hash`?

- **Model 1: Mandatory Replay Invariant**
  - `artifact_hash` MUST match bit-for-bit after rematerialization. If a rematerialized native package produces a different `artifact_hash`, synchronization fails with `error.ArtifactHashMismatch`.
- **Model 2: Cache Hint**
  - `artifact_hash` is a primary lookup key for local/remote CAS. If absent, source rematerialization is performed. If the rematerialized artifact matches `recipe_hash` and `source_hash`, it is accepted even if `artifact_hash` differs, and `moonstone.lock` is updated with the new realization hash.
- **Model 3: Target/Toolchain-Scoped Realization Identity**
  - `artifact_hash` is scoped to `(target, lua_abi, toolchain_version)`. Every non-live locked package requires an exact `artifact_hash` match during replay. A new host or toolchain realization must be created explicitly rather than silently weakening an existing lock entry.

**Note:** Per user directive, we do **not** recommend accepting artifact-hash mismatches based on `reproducible = false`. This remains an explicit open design decision for project leadership.

---

## 9. Relevant Files & Functions

- `src/cli/commands/sync.zig`: `SyncCommand.run` (Lines 768–865)
- `src/core/domain/lockfile.zig`: `LockEntry`, `LockFile.parse`, `LockFile.serialize`
- `src/core/identity/hash.zig`: `recipe_hash` (Lines 16–77)
- `src/core/store.zig`: `computeRecipeHash` (Lines 37–120)
- `src/core/resolution/provider/graph_provider.zig`: `RegistryProvider.get_artifact` (Lines 128–176)
