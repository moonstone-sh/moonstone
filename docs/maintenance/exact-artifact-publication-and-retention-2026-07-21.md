# Exact Artifact Publication and Registry Retention v1

**Author**: Antigravity  
**Date**: 2026-07-21  
**Status**: Implemented & Certified  

---

## 1. Executive Summary

This document describes the design and implementation of Moonstone's **Exact Artifact Publication & Registry Retention v1** service. It completes the producer side of Moonstone's content-addressed artifact protocol, enabling verified local CAS realizations to be encoded into canonical transport objects (`moonstone:artifact-transport:v1`) and published idempotently to remote artifact providers by `artifact_hash`.

---

## 2. Blocking Correction: `ArtifactRequest` Target Identity

- **Correction**: Removed the default context-sensitive `target: []const u8 = "native"` from `ArtifactRequest`.
- **Enforcement**: All artifact lookups and publish requests require an explicit concrete target (e.g. `aarch64-macos`, `x86_64-linux`).
- **Invariant**: The `artifact_hash` remains the primary lookup key, while target identity is strictly validated against the selected realization metadata.

---

## 3. Publication Protocol & Transport Encoding (`publisher.zig`, `transport.zig`)

```text
local CAS record
 ├── 1. Validate local tree & recompute artifact_hash
 ├── 2. Encode canonical transport package (tar/zst) -> TransportInfo
 ├── 3. Publish to RemoteArtifactPublisher (PUT /artifacts/v1/b3/<hash>)
 └── 4. Idempotent Storage:
        ├── New artifact: validate & make visible -> status = .created
        ├── Existing artifact: return status = .already_present
        └── Hash/Bytes mismatch: reject -> status = .conflict
```

---

## 4. Retention Roots & Package Association (`retention.zig`)

Artifact retention is governed by explicit retention roots (`RetentionRoot`):

- `published_package_version`: Immutable retention for published registry packages.
- `active_release`: Release matrix artifacts.
- `private_project_lock`: Registered project lockfile references.
- `manual_pin` / `retention_lease`: Admin pins and lease extensions.

Package associations (`ArtifactAssociation`) link content-addressed `artifact_hash` instances to package names, versions, targets, and publisher identities for permission checks and quarantine event auditing.
