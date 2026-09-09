# Lockfile v3: immediate `--locked` replay rejects a freshly updated multi-profile lock

Status: reproducible; defer implementation assessment

Observed on 2026-09-09 with Moonstone v0.4.9 while moving `hydronium/create`
into the Hydronium Orbits workspace.

## Summary

`moon sync --update` succeeds and writes a lockfile, but an immediate
`moon sync --locked` against the unchanged manifest rejects that lock as out of
sync:

```text
$ moon sync --update
Updating lockfile within declared constraints...
Resolved 10 dependencies.
Linking project environment...

$ moon sync --locked
Error: moonstone.lock is out of sync with moonstone.toml. Run 'moon sync' to update it.
```

The same failure occurs through Orbits:

```text
$ moon orbit sync create --locked
Error: Orbit 'create' at '.../hydronium/create' failed to synchronize
       (LockfileOutOfSync).
```

This blocks a Ballad parent partiture from exporting the child with
`moonstone.orbit(...):run({ sync = "locked" })`, even though the child was just
successfully synchronized.

## Reproducer shape

The project uses LuaJIT 2.1 / ABI 5.1 and declares, among other dependencies:

```toml
[[dependencies]]
name = "moonstone/ballad"
constraint = "^0.3.7"
role = "tool"

[[dependencies]]
name = "moonstone/clingy"
constraint = "^0.4.0"
role = "runtime"
```

The v3 lock legitimately contains multiple profiles. The Lua 5.4 tool closure
contains `moonstone/clingy@0.2.0`, while the project's LuaJIT 5.1 profile
contains `moonstone/clingy@0.4.0`.

The failure reproduces both in the original standalone `hydronium-create`
project and after importing it as `hydronium/create`. It is therefore not
caused by the repository move or by an Orbit-relative path.

## Contradictory diagnostics

For the same manifest and lockfile, `moon doctor` reports:

```text
[ ] Checking lockfile_sync... OK
```

while `moon sync --locked` returns `LockfileOutOfSync`. The two commands appear
to use different definitions of lock/manifest agreement.

## Probable cause from source inspection

`lockedDependenciesMatch` in `src/cli/commands/sync.zig` scans the lockfile's
global realization list and stops at the first entry whose package name
matches the manifest dependency:

```zig
for (lf.packages.items) |*entry| {
    if (packageNamesMatch(entry.name, dep_name)) {
        found_entry = entry;
        break;
    }
}
```

It then checks that one entry's version against the manifest constraint. In a
multi-profile v3 lock, the first matching realization need not belong to the
active profile or role. Here it finds Clingy 0.2.0 from the Lua 5.4 tool
closure, rejects it against `^0.4.0`, and never considers the valid Clingy
0.4.0 realization referenced by the active LuaJIT profile.

## Expected behavior

- A successful `moon sync --update` followed by an unchanged
  `moon sync --locked` must succeed.
- Validation must be profile- and role-aware for lockfile v3.
- Different compatible versions of the same package in independent runtime or
  tool profiles must not make the lock intrinsically unreplayable.
- `moon doctor` and `moon sync --locked` should agree and explain the specific
  dependency/profile mismatch when they fail.

## Assessment points for a later fix

1. Validate direct manifest dependencies against realizations referenced by
   the applicable profile instead of the global realization list.
2. If global validation remains necessary, examine every matching realization
   rather than accepting or rejecting solely from the first one; preserve role
   and profile identity so an unrelated tool closure cannot satisfy the check.
3. Share the same validation routine between `moon doctor`, `moon sync
   --check`, and `moon sync --locked`.
4. Add a regression fixture with two profiles containing different versions of
   the same package and assert that update-to-locked replay is idempotent.
5. Improve `LockfileOutOfSync` diagnostics to include the dependency,
   constraint, selected realization, profile, and role.
