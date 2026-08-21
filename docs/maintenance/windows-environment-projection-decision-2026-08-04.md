# Windows Environment Projection Decision — 2026-08-04

## Status

**Current policy: symlinks only on every supported host, including Windows.**

Moonstone's `.moonstone/env/` is a projected view of immutable runtime and
package artifacts. It must remain a linked environment rather than a copied
deployment directory. This preserves the repository's existing environment
contract and ensures that a live linked package remains live.

The implementation point is `src/core/project/linker.zig`:

- projected binaries and module files use file symbolic links;
- complete `libexec` package roots use directory symbolic links;
- selectively projected trees create only destination directories and link
  their file leaves;
- Windows directory links specify `is_directory = true`, which is required by
  the Windows symlink API.

## Why not copy on Windows

Windows can deny symlink creation when Developer Mode, the appropriate policy,
or sufficient privileges are unavailable. A copy fallback would make `moon
sync` appear successful, but it changes the meaning of the projection:

- a live link would silently become stale after its first copy;
- a copied artifact closure would no longer demonstrate the same link topology
  as Unix environments;
- refresh and invalidation semantics would become host-dependent;
- users and tools could not distinguish a real projected environment from a
  materialized snapshot without another protocol field.

That hidden semantic shift is worse than a clear Windows symlink permission
error during the current beta.

## Current Windows support boundary

Moonstone supports Windows-specific projection mechanics without weakening the
environment model:

| Concern | Current behavior |
| --- | --- |
| Native module paths | `LUA_CPATH` projects `.dll` patterns. |
| Direct commands | Lookup tries the exact name, then `.exe`, `.cmd`, and `.bat`. |
| Generated live-link tool shims | Emit `.cmd` files. |
| Script execution | Uses `cmd /d /s /c` on Windows. |
| Environment links | Require real symbolic links. |

The corresponding native smoke is `tests/windows/core.ps1`; both
`x86_64-windows-gnu` and `aarch64-windows-gnu` cross-builds remain required
compile-time boundaries. The x86_64 target also has native GitHub Windows
execution coverage; Windows ARM64 currently has compile and release-matrix
coverage until an ARM runner is added.

## Alternatives deliberately deferred

### Directory junctions

Junctions are a promising future fallback for **whole live-link directories**:
they usually avoid symlink privilege requirements and preserve live updates.
They are not a replacement for file links, and they need explicit lifecycle,
deletion, and cross-volume tests before becoming part of the projection
contract.

### Hard links

Hard links apply only to files on the same volume. They do not model linked
directories and would couple the CAS and project layout to volume placement.
They are not a general environment projection mechanism.

### Copies

Copies are suitable for an explicit future export or deployment closure, not
for `.moonstone/env/`. If introduced, they must be an opt-in materialization
mode with visible status and separate freshness guarantees.

## Revisit criteria

Revisit this decision only when Moonstone can add one of the following without
changing semantics implicitly:

1. a tested junction implementation for directory live links;
2. an explicit copy/export mode distinct from project environment projection;
3. a platform capability diagnostic that tells the user how to enable Windows
   symbolic links before sync begins.

Until then, failure to create a Windows symlink is intentional and actionable:
enable Developer Mode or run with a policy/account allowed to create symbolic
links.
