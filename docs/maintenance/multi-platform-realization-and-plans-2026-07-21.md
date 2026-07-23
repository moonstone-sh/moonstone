# Multi-Platform Resolution Profiles and Language-Agnostic Materialization Plans

**Author**: Antigravity  
**Date**: 2026-07-21  
**Status**: Implemented & Verified  

---

## 1. Executive Summary

This document describes the design and implementation of Moonstone's **Multi-Platform Resolution Profiles** and **Language-Agnostic Materialization Plans**. This architecture allows a single `moonstone.lock` lockfile to express multiple target/runtime environments (e.g. `aarch64-macos` and `x86_64-linux`) without altering frozen replay invariants or re-resolving dependencies.

---

## 2. Multi-Platform Resolution Profiles

### 2.1 Profile Identity & Selection (`resolution_profile.zig`)
A `ResolutionProfile` represents one target/runtime resolution context:

```text
ResolutionProfile
 ├── id: []const u8 ("aarch64-macos+lua-5.4+5.4")
 ├── target: []const u8 ("aarch64-macos")
 ├── runtime: []const u8 ("lua-5.4")
 ├── lua_abi: ?[]const u8 ("5.4")
 ├── packages: []ProfilePackageRef (maps package identity to exact realization_hash)
 └── edges: []DependencyEdge (explicit profile graph edges)
```

- **Selection**: `selectProfile(profiles, active_target, active_runtime, active_lua_abi)` selects the exact matching profile.
- **Missing Profile**: If no profile matches during frozen replay, Moonstone returns `error.MissingResolutionProfile` rather than mutating or re-resolving.
- **Existing Profile Immutability**: Adding a new profile (`moon sync --add-profile`) appends the new profile transactional record while keeping existing profiles byte-for-byte unchanged.

---

## 3. Language-Agnostic Materialization Plans

### 3.1 Materialization Plan Schema (`plan.zig`)
The `MaterializationPlan` (`moonstone:plan:v1`) decouples build tool ecosystems (Pure Lua, Zig CC, CMake, Cargo, Go, Node) from Moonstone's execution core:

```text
MaterializationPlan
 ├── schema: "moonstone:plan:v1"
 ├── package_name / package_version / target
 ├── inputs: []PlanInput (verified source tree, dependency artifacts, toolchains)
 ├── tools: []ToolRequirement (id, executable, assurance: declared_host_tool)
 ├── environment: []EnvPair (bounded build environment)
 ├── steps: []PlanStep (direct argv invocation without shell strings!)
 ├── outputs: []OutputRule (declared copy_file, copy_tree, lua_module, lua_cmodule, executable)
 └── network: NetworkPolicy (denied / allowed)
```

### 3.2 Materializer Adapters (`adapter.zig`)

| Adapter | Schema | Steps | Network Policy | Replay Assessment |
| :--- | :--- | :--- | :--- | :--- |
| **PureLuaAdapter** | `moonstone:plan:v1` | 0 steps (copy rules only) | `denied` | `.source_replay_supported` |
| **ZigCcAdapter** | `moonstone:plan:v1` | `zig cc -shared -o output.so ...` | `denied` | `.exact_artifact_required` |
| **CmakeAdapter** | `moonstone:plan:v1` | 1: `cmake -B build`<br>2: `cmake --build build` | `denied` | `.exact_artifact_required` |

---

## 4. Generic Recipe Executor (`executor.zig`)

The `RecipeExecutor` processes plans through two distinct phases:

1. **Validation (`validatePlan`)**:
   - Rejects relative path traversal containing `..` or absolute `/` paths (`error.InvalidPlanPath`).
   - Ensures all tools referenced by steps are explicitly declared (`error.UndeclaredTool`).
2. **Execution (`executePlan`)**:
   - Executes process steps using direct `argv` arrays (no ambient `sh -c` shell string concatenation!).
   - Binds declared execution environment.
   - Collects declared output files and trees into the destination artifact directory.

---

## 5. Verification Matrix & Unit Tests

The implementation was verified using the unit test suite in `tests/unit/multi_profile_plan_test.zig`:

1. **Profile Identity & Selection**:
   - Verified profile ID generation (`aarch64-macos+lua-5.4+5.4`).
   - Verified cross-platform profile selection between Mac ARM64 and Linux x86_64.
2. **Plan Validation & Security**:
   - Rejection of path traversal (`../etc/passwd`) -> `error.InvalidPlanPath`.
   - Rejection of undeclared tool invocation -> `error.UndeclaredTool`.
3. **Materializer Adapter Assessment**:
   - Verified replay assessments for `PureLuaAdapter`, `ZigCcAdapter`, and `CmakeAdapter`.
