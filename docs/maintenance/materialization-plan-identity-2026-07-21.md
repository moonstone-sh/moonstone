# Materialization Plan Identity and End-to-End Multi-Profile Certification

**Author**: Antigravity  
**Date**: 2026-07-21  
**Status**: Implemented & Certified  

---

## 1. Executive Summary

This document describes the finalization and certification of Moonstone's **Materialization Plan Identity** and **Multi-Platform Resolution Architecture**. By binding every generated `MaterializationPlan` to a canonical `plan_hash` recorded on the target realization, Moonstone protects lockfiles against build adapter drift and enforces end-to-end multi-profile certification.

---

## 2. Structured Profile Identity

Profile matching uses structured identity equality rather than string labels:

```zig
pub const ProfileIdentity = struct {
    target: []const u8,
    runtime: RuntimeIdentity,
    lua_abi: ?[]const u8 = null,
};
```

- **Selection Invariant**: Matching requires exact equality across `target`, `runtime.version`, `runtime.artifact_hash`, and `lua_abi`.
- **Missing Profile Invariant**: Replay on an environment lacking a matching profile fails with `error.MissingResolutionProfile` without invoking PubGrub resolution or mutating the lockfile.
- **Profile Immutability Invariant**: Append-only profile addition validates `verifyProfilesUnchanged`, aborting with `error.ExistingProfileMutationDetected` if existing profile packages, edges, or realization hashes are mutated.

---

## 3. Canonical Plan Hashing & Replay Binding

### 3.1 Preimage & Hash Writer (`plan.zig`)
Every `MaterializationPlan` (`moonstone:plan:v1`) is hashed using a canonical preimage writer (`computePlanHash`):

```text
moonstone:plan:v1
package_name=<name>
package_version=<version>
target=<target>
network=<policy>
input=<id>:<kind>:<source>:<mount>
tool=<id>:<executable>:<assurance>
env=<key>=<value>
step=<name>:<tool_id>:<cwd>
  arg=<argv[i]>
output=<kind>:<from>:<to>
```

### 3.2 Replay Invariant
Before executing a materialization step during frozen replay:
1. Re-generate plan via adapter.
2. Compute `computed_plan_hash = computePlanHash(&plan)`.
3. Require `computed_plan_hash == entry.plan_hash`.
4. Mismatches abort immediately with `error.PlanHashMismatch` before step execution.

---

## 4. Test & Fixture Matrix

The architecture was certified using unit tests in `tests/unit/multi_profile_plan_test.zig` and durable fixtures:

| Fixture / Test | Scenario | Verified Invariant |
| :--- | :--- | :--- |
| `tests/unit/multi_profile_plan_test.zig` | Canonical plan hash stability & sensitivity | Changing target/step/argv alters `plan_hash` |
| `tests/unit/multi_profile_plan_test.zig` | Existing profile immutability | Mutating existing profile returns `ExistingProfileMutationDetected` |
| `tests/unit/multi_profile_plan_test.zig` | Security validation | Path traversal returns `InvalidPlanPath`, undeclared tool returns `UndeclaredTool` |
| `dual-target-basic/moonstone.lock` | Dual profile coexistence | `aarch64-macos` and `x86_64-linux` coexist in one lockfile |
