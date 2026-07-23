# Universal Realization v1 Closure and Scope Freeze

**Author**: Antigravity  
**Date**: 2026-07-21  
**Status**: Completed & Scope Frozen  

---

## 1. Architectural Scope Statement

> **Moonstone does not provision complete general-purpose build environments. External compilers, SDKs, and package-manager toolchains may be used to produce target artifacts, but exact cross-machine replay is provided through Moonstone’s content-addressed artifact system.**

---

## 2. Supported Guarantees

Moonstone freezes Lua dependency resolution and records exact target-specific artifact realizations. It restores those artifacts from local or remote content-addressed storage (`b3:<hash>`). Pure-Lua packages may also be rematerialized from locked source. Native and external-tool builds may use declared host tools to produce artifacts, but strict replay consumes the exact published artifact rather than reproducing the entire host toolchain.

---

## 3. Realization Assurance Levels (`RealizationAssurance`)

| Materializer | Assurance Level | Store-Miss / Replay Behavior |
| :--- | :--- | :--- |
| **Pure Lua (copy/collect)** | `portable_source` | Rebuild from locked source archive |
| **Zig CC (native C module)** | `declared_host` | Exact artifact required (remote CAS or local) |
| **CMake** | `declared_host` | Exact artifact required (remote CAS or local) |
| **Custom Commands** | `artifact_only` | Exact artifact required |

---

## 4. Production Recovery Priority

```text
1. Local CAS lookup (by artifact_hash)
   └─► Found: return .local_cas

2. Remote Artifact Provider (by exact artifact_hash & expected target)
   └─► Verified & Committed: return .remote_artifact

3. Source Rematerialization (if assurance == .portable_source)
   └─► Pure Lua: rebuild & verify -> return .source_rematerialization

4. Terminal Failure
   └─► Return error.ExactArtifactRequired
```

---

## 5. Retention & Authorization Enforcement

- **Retention Roots (`RetentionRoot`)**: Garbage collection checks `published_package_version`, `active_release`, `private_project_lock`, `manual_pin`, and `retention_lease` roots before eviction. Retained artifacts survive GC.
- **Quarantine Enforcement (`shouldServeArtifact`)**: Quarantined artifacts are rejected and not served under any circumstances, regardless of retention roots.
- **Credential Protection**: Authentication tokens exist only in memory during authenticated runtime sessions and are never logged, traced, or written to lockfiles.

---

## 6. Explicit Non-Goals

The following areas are explicitly frozen and out of scope:
- Provisioning Zig, Rust, Go, Node, CMake, SDKs, or libc toolchains.
- Implementing a Nix-like derivation engine.
- Re-resolving dependencies during frozen lock replay.
- Automatically rebuilding missing native artifacts during replay without an exact artifact match.
- Weakening `artifact_hash` bit-for-bit verification.
