# Universal Lockfile Realization v1 & Pure-Lua Clean-Store Replay

**Author**: Antigravity  
**Date**: 2026-07-21  
**Status**: Implemented & Verified  

---

## 1. Executive Summary

This document describes the implementation of Moonstone's Universal Lockfile Realization v1 architecture. The implementation establishes explicit domain boundaries between **frozen package resolution** and **target-specific artifact realizations**, introduces the `LockedArtifactRealizer` domain service, fixes resolver provenance loss (`resolver = "store"` bug), and provides deterministic clean-store replay for pure-Lua packages.

---

## 2. Implemented Domain Types

The explicit lock domain types are implemented in `src/core/domain/locked_package.zig` and exported via `domain.locked_package`:

### 2.1 Domain Model Overview

```text
LockedPackage (Resolution Identity)
 ├── name: []const u8
 ├── version: []const u8
 ├── provenance: ResolverProvenance (rocks, moonstone, link, path, etc.)
 ├── source: LockedPayload (hash, locators)
 ├── rockspec: ?LockedPayload
 └── realizations: []TargetRealization (Target Realizations)
       ├── target: []const u8
       ├── lua_abi: ?[]const u8
       ├── runtime_artifact_hash: ?[]const u8
       ├── recipe_hash: []const u8
       ├── artifact_hash: []const u8
       └── recipe: RecipeV2 (17-field canonical recipe preimage)
```

### 2.2 Materializer Capability Matrix

| Materializer Strategy | Store-Miss Behavior | Replay Capability |
| :--- | :--- | :--- |
| Pure-Lua (`copy_lua`, `builtin`, `rocks`) | Source Rematerialization | `.source_replay_supported` |
| Native C Modules (`zig cc`) | Local CAS or Exact Remote Artifact | `.exact_artifact_required` |
| CMake | Local CAS or Exact Remote Artifact | `.exact_artifact_required` |
| Custom Commands | Local CAS or Exact Remote Artifact | `.exact_artifact_required` |

---

## 3. Resolver Provenance Preservation

Previous versions of Moonstone overwrote `pkg.origin = .artifact_hash` when loading candidates from the local CAS, causing `moon sync` to serialize `resolver = "store"`.

The implementation preserves original resolver provenance (`rocks`, `moonstone`, `link`, `path`) during lockfile generation and frozen replay:

```zig
.resolver = try allocator.dupe(u8, switch (pkg.origin) {
    .luarocks => "rocks",
    .moonstone_registry => "moonstone",
    .link => "link",
    .path => "path",
    .artifact_hash => blk: {
        if (existing_lock.find(pkg.name)) |ex_pkg| {
            if (ex_pkg.resolver.len > 0 and !std.mem.eql(u8, ex_pkg.resolver, "store")) {
                break :blk ex_pkg.resolver;
            }
        }
        if (store_rockspec.len > 0) break :blk "rocks";
        break :blk "store";
    },
});
```

---

## 4. Replay Call Graph & State Machine

When `moon sync` executes with an existing lockfile (`replay_lock == true`), resolution is completely bypassed and delegation proceeds through `LockedArtifactRealizer`:

```text
moon sync (replay_lock == true)
  │
  ▼
LockedArtifactRealizer.ensureLockedArtifact()
  │
  ├─► Step 1: Check Local CAS by artifact_hash (StoreDriver.get_artifact)
  │      └── Found: Return RealizeResult{.method = .local_cas}
  │
  ├─► Step 2: Assess Materializer Capability
  │      └── Native C / CMake / Command -> fail with error.ExactArtifactRequired
  │
  ├─► Step 3: Pure-Lua Source Rematerialization
  │      ├── Retrieve & verify rockspec / source payloads (local cache or HTTP)
  │      ├── Verify exact source_hash
  │      ├── Reconstruct RecipeV2 preimage & verify recipe_hash
  │      ├── Execute pure-Lua materialization
  │      ├── Compute rebuilt artifact_hash
  │      ├── Verify exact equality (rebuilt == locked artifact_hash)
  │      └── Commit rematerialized artifact to local CAS
  │
  └── Return RealizeResult{.method = .source_rematerialization}
```

---

## 5. Verification Matrix & Test Results

The implementation was validated using isolated temporary directories (`MOONSTONE_HOME`, `MOONSTONE_CONFIG`, `MOONSTONE_DATA`, `MOONSTONE_CACHE`) across four critical scenarios:

1. **Clean-Store Pure-Lua Replay**:
   - `moon init` & `moon add rocks:inspect`
   - Wipe `$MOONSTONE_HOME/store`, `$MOONSTONE_DATA/store`, `$MOONSTONE_DATA/index`
   - `moon sync` (succeeds via `ensureLockedArtifact` source rematerialization)
   - `moon exec lua -e 'local inspect = require("inspect"); print(type(inspect))'` -> `INSPECT_OK=table`
2. **Strict Artifact-Hash Verification**:
   - Rebuilt artifact hash is strictly matched against locked `artifact_hash` bit-for-bit.
3. **No Resolution / Lockfile Mutation During Replay**:
   - PubGrub solver is not invoked when replaying existing lockfiles.
   - Lockfile is not modified or rewritten during frozen replay.
4. **Native C / CMake Missing Artifact Handling**:
   - Native C or CMake packages without local or pre-built artifacts accurately fail with `ExactArtifactRequired`.

---

## 6. Deferred Follow-Up Work

1. **Hermetic Toolchains for Native C**: Integration of hermetic Zig toolchain closures for deterministic native module recompilation from clean store.
2. **Exact Remote Artifact Registry Protocol**: Specification of remote pre-built binary artifact endpoint.
3. **Multi-Target Realization CLI Command**: Explicit CLI flag for adding targets to multi-realization lockfiles.
