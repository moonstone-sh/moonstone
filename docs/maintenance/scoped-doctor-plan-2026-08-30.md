# Tentative Plan: Scoped `--doctor`

**Date:** 2026-08-30
**Status:** Tentative design note

This is an incremental extension of diagnostics, not a replacement for
`moon doctor`. `moon doctor` remains the full health command and keeps its
exhaustive system/project checks. This proposal adds a read-only diagnostic
protocol for a small number of command scopes.

## Scope and command meanings

The first supported forms are:

```text
moon --doctor
moon provision --doctor
```

The later form is:

```text
moon provision resolve <name> --doctor
```

`--doctor` changes the selected invocation into inspection mode: it reports
the checks for that scope and does not perform the command's normal action.
Thus `moon provision --doctor` diagnoses the provision subsystem as a whole,
while the later `resolve <name> --doctor` diagnoses one named resolution.
`moon --doctor` is the root, invocation/project-context scope; it is not an
alias for the full `moon doctor` suite. Help should point users to
`moon doctor` for the complete check.

## Safety policy

Scoped doctor is strictly read-only:

- no manifest, lockfile, environment, store, index, cache, shim, or temporary
  workspace mutation;
- no repair, deletion, creation, linking, compilation, or subprocess whose
  purpose is mutation;
- no network access, registry request, download, upload, credential lookup, or
  network fallback;
- no resolution or materialization that would write or populate state. Existing
  local metadata and artifacts may be inspected and hashes may be verified in
  memory.

The implementation should use read-only database handles and avoid APIs that
implicitly create missing directories or databases. An unavailable remote or
missing local input is a diagnostic finding, not permission to go online.

## Output and exit contract

Human mode prints concise check lines and a final summary, with actionable
context but no repair prompt. It should use the command's established output
stream conventions and never print machine-readable lines into NDJSON output.

NDJSON mode follows [`CLI_NDJSON_PROTOCOL.md`](../CLI_NDJSON_PROTOCOL.md): emit
`START`, one `STATUS`, `WARN`, or `ERROR` event per check, and exactly one
terminating `RESULT` for the selected scope. Include a stable `about` value
(`root-doctor`, `provision-doctor`, or `provision-resolve-doctor`) and a
`data` object containing check code, state, and bounded detail. `START` should
identify the read-only mode (for example, `{ "doctor": true, "mutating":
false }`). The final result is `ok` for no errors, `partial` when warnings or
failed checks are present, and `aborted` for invalid invocation or an
unreadable fatal diagnostic input; always set `terminator: true` on that final
event.

Exit status is independent of renderer: `0` means all requested checks passed
(warnings alone do not fail); `1` means one or more checks found an issue; `2`
means invalid usage or an internal inability to produce the scoped report.
The process must not claim success merely because a check was skipped due to
the no-network policy.

## Dispatch design

Parse `--doctor` as a scoped modifier after global options and before command
execution, retaining the positional command path for scope selection. Dispatch
to a `DoctorScope` handler before entering the normal command handler. The
handler receives the already parsed context plus an explicit read-only policy;
it must not call the mutating provision, resolve, sync, or materialization
path. Unknown placements, extra operands, and unsupported command scopes are
usage errors rather than silently falling through to normal behavior.

The dispatch table should make supported scopes explicit, so adding a later
scope is a deliberate compatibility change. Do not infer that every command
accepts `--doctor`, and do not make the flag a synonym for `--dry-run`.

## Minimum provision diagnostics

`moon provision --doctor` should initially inspect, without changing:

1. provision-store/index readability and schema integrity;
2. provision records have valid kinds, paths, hashes, and runtime/ABI data;
3. referenced artifact paths exist and are regular, safe entries in the CAS;
4. provision-to-artifact references are internally consistent and not dangling;
5. declared executable/module/native-library paths are normalized and do not
   escape their artifact or projected environment roots;
6. target and ABI fields are compatible with the selected local context, when
   that context exists; and
7. for `resolve <name>`, the name is present, its candidate metadata is
   locally inspectable, and the resulting provision closure is complete.

Missing local data should be reported with a stable check code and remediation
hint (usually `moon sync` or `moon doctor`), never fetched or synthesized.

## Rollout

1. **Protocol:** document scope names, safety invariants, result/exit mapping,
   and focused parser/dispatch tests; no user-facing support yet.
2. **Root scope:** implement `moon --doctor` with read-only context checks and
   human/NDJSON output.
3. **Provision scope:** add the minimum checks above to `moon provision
   --doctor`; certify that empty, corrupt, dangling, and valid stores produce
   the promised statuses without mutation or network activity.
4. **Named resolution:** add `moon provision resolve <name> --doctor` only after
   provision diagnostics have stable check identities and local-only lookup
   semantics.
5. **Review:** compare the scoped checks with the full `moon doctor` contract,
   then decide whether any stable diagnostics belong in the full command.

## Explicit non-goals

- Do not universally add `--doctor` to all commands yet.
- Do not add an `env clean` command or imply that doctor performs cleanup.
- Do not change normal command behavior, mutation ordering, network behavior,
  output, or exit status when `--doctor` is absent.
- Do not make scoped doctor repair, resolve online, download, materialize, or
  replace the full `moon doctor` health suite.

The broader architecture remains governed by [`ARCHITECTURE.md`](../ARCHITECTURE.md),
especially its CAS immutability, SQLite, and resilience invariants. The event
shape and terminator rules remain governed by
[`CLI_NDJSON_PROTOCOL.md`](../CLI_NDJSON_PROTOCOL.md), rather than introducing
a second diagnostic stream format.
