# Exact Remote Artifact Retrieval v1 and Multi-Profile Certification

**Author**: Antigravity  
**Date**: 2026-07-21  
**Status**: Implemented & Certified  

---

## 1. Executive Summary

This document describes the design and implementation of Moonstone's **Exact Remote Artifact Retrieval v1** service and final multi-profile certification. It establishes a content-addressed recovery pipeline keyed strictly by `artifact_hash` without invoking PubGrub dependency resolution or project manifest parsing.

---

## 2. Artifact Recovery Sequence (`locked_realizer.zig`)

When `ensureLockedArtifact` executes during frozen replay:

```text
ensureLockedArtifact
 ├── 1. Check Local CAS by artifact_hash
 │      └── Found: Return RealizeResult{.method = .local_cas}
 │
 ├── 2. Remote Artifact Providers (if online and enabled)
 │      ├── Query configured RemoteArtifactProvider by exact artifact_hash
 │      ├── Extract into isolated staging directory
 │      ├── Validate security invariants (no traversal, no device files)
 │      ├── Verify exact computed artifact_hash == locked artifact_hash
 │      ├── Atomically commit verified artifact into local CAS
 │      └── Return RealizeResult{.method = .remote_artifact}
 │
 ├── 3. Assess Source Rematerialization Capability
 │      ├── Pure Lua (`copy_lua`, `builtin`): `.source_replay_supported`
 │      └── Native C (`zig cc`) / CMake / Custom: `.exact_artifact_required`
 │
 └── 4. Pure-Lua Source Rematerialization
        ├── Rebuild pure-Lua artifact tree from verified source archive
        ├── Verify exact artifact_hash match
        └── Return RealizeResult{.method = .source_rematerialization}
```

---

## 3. Remote Artifact Provider Contract (`provider.zig`)

The `RemoteArtifactProvider` receives a domain `ArtifactRequest` and retrieves content-addressed artifact trees:

```zig
pub const ArtifactRequest = struct {
    artifact_hash: []const u8,
    artifact_schema: []const u8 = "moonstone:artifact-tree:v1",
    target: []const u8 = "native",
};
```

- **Security & Extraction Validation**:
  - Path traversal checks (rejects `..` paths or absolute `/` paths).
  - Verifies local directory tree against locked `artifact_hash`.
  - Rejects hash mismatches before CAS commit (`.hash_mismatch`).
- **Secret & Credential Redaction**: Authentication tokens are maintained in memory during runtime sessions and never serialized into lockfiles, logs, or diagnostic traces.

---

## 4. Verification Matrix & Certification

- **Clean Store Native & CMake Replay**: Pre-built native and CMake package realizations are retrieved remotely by `artifact_hash` on clean stores without invoking local compilers or build tools.
- **Pure-Lua Source Fallback**: When remote providers miss a pure-Lua package, recovery falls back to deterministic source rematerialization.
- **Offline Invariant**: Offline mode (`--offline`) bypasses remote providers and relies exclusively on local CAS and cached source payloads.
