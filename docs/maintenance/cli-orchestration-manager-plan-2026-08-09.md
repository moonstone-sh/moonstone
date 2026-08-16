# CLI Orchestration Manager Completion Plan

## Purpose

Moonstone already schedules concurrent realization work, renders bounded task
rows, and emits NDJSON task events. This plan turns those pieces into one
reusable command-orchestration contract rather than a `sync`-specific
convention.

The invariant is:

> Workers describe task state. One command-scoped manager owns task identity,
> ordering, terminal rows, human output, and NDJSON serialization.

## Current implementation

| Area | Current implementation | Gap |
| --- | --- | --- |
| Work claiming | `src/core/realization/scheduler.zig` has bounded, fail-fast workers and cancellation checks. | It deliberately has no lifecycle or identity model. |
| Human progress | `src/cli/progress.zig` owns terminal drawing and caps visible rows at five. | Rows are `swapRemove`d on completion, so remaining work can jump between terminal lines. |
| Worker reporting | `WorkerContext.sendTaskState` accepts `(task_id, revision, state, message)`. | Ownership is duplicated in every pool and IDs are caller-formatted strings. |
| NDJSON | `src/cli/commands/ndjson.zig` serializes run-scoped sequence numbers and task-state events. | Producers duplicate data/revision conventions. |
| Sync pools | `DownloadPool`, `RocksPool`, and `LockedReplayPool` report lifecycle states. | IDs are package-only (`materialize:name@version` / `replay:name@version`) and collide across target profiles. |
| Output modes | `moon sync` supports fancy, plain, quiet, and NDJSON. | Other concurrent command families have not adopted the same façade. |

## Contract

### Task identity

The manager owns a stable task id. Realization tasks use:

```text
realize:<target>:<resolver>:<package>@<version>
replay:<target>:<resolver>:<package>@<version>
```

The target is always concrete for a `sync` profile. Resolver is included so a
registry package and a rock with the same name cannot collapse into one row.
Future substeps may append a final segment, but may not change the existing
prefix meaning.

### State ownership

Workers may submit only structured lifecycle updates:

```text
queued -> preparing -> running -> reused | completed | failed | cancelled
```

Each update carries a monotonically increasing revision. The manager discards
older revisions and is the sole writer of terminal rows and NDJSON envelopes.

### Terminal rows

The manager assigns an active task a stable slot on first non-terminal update.
A terminal task frees its slot without moving another active task into that
slot. Render order is slot order, not completion order. Five active slots are
shown; remaining tasks are represented by one overflow summary line.

### Output modes

- **fancy:** the manager repaints owned task slots.
- **plain:** one durable transition line per state change; no cursor control.
- **quiet:** no lifecycle output; process exit status only.
- **NDJSON:** one serialized envelope per event; no human output.

## Delivery phases

### Phase 1 — Shared identity and stable rows

1. Add a small CLI task protocol module for canonical realization/replay ids.
2. Pass profile target and resolver identity into all `sync` pools.
3. Replace `swapRemove` task rows with fixed active slots.
4. Add unit tests for target/resolver isolation, revision suppression, stable
   slots, overflow behavior, and terminal slot release.

### Phase 2 — Lifecycle façade

1. Add one producer helper that forwards the same lifecycle update to the
   progress queue and NDJSON emitter.
2. Migrate `DownloadPool`, `RocksPool`, and `LockedReplayPool` away from
   repeated `emitTask` / `sendTaskState` pairs.
3. Keep command-specific metadata at the call site; keep revision/state and
   identity mechanics in the façade.

### Phase 3 — Command-family adoption

1. Migrate `orbit sync` to the same façade. **Implemented as one parent-owned
   lifecycle task per orbit.** Child sync remains serial and silent because it
   currently changes the process-wide CWD; adding parallel orbit sync before
   project roots are explicit command inputs would be unsafe.
2. Adopt it for registry/index download work and long-running store commands.
3. Make `--jobs`, `--progress`, `--quiet`, and `--json` semantics consistent
   wherever a command schedules concurrent work.

### Phase 4 — Request coordination

1. Add a request-keyed in-flight map above the scheduler, keyed by canonical
   source/recipe inputs rather than package display names.
2. Return followers a reference to the leader’s outcome rather than scheduling
   duplicate source work.
3. Pair in-process coordination with the existing cross-process recipe lock
   before materialization starts.

## Non-goals

- The scheduler does not become a renderer or NDJSON serializer.
- Workers never reserve arbitrary terminal lines or print spinners.
- The manager does not infer task dependencies or become a workflow engine.
- NDJSON remains append-only events; it is not a terminal rendering protocol.

## Certification

Phase 1 is complete when task ids are target/resolver scoped, active rows do
not reorder on another task completing, revisions are idempotent, and fancy,
plain, quiet, and NDJSON still preserve their existing command contracts.

Phase 2 is complete when sync pools have one lifecycle forwarding path.
Phase 3 is complete when every concurrent CLI command uses that path.
Phase 4 is complete when duplicate source requests across workers and processes
share one materialization result safely.

## Implemented slice

Phases 1 and 2 are implemented for `moon sync`; Phase 3 is implemented for
`orbit sync` and its output modes:

- `src/cli/task_protocol.zig` formats realization and replay identities with
  task kind, concrete target, resolver, package name, and version.
- `DownloadPool`, `RocksPool`, and `LockedReplayPool` report through one
  lifecycle adapter so the terminal queue and NDJSON stream receive the same
  revisioned event.
- `ProgressUi` owns five stable slots. Completing a task frees only its own
  slot; an overflow task may fill that empty slot, but no active task is moved.

`orbit sync` now uses the same lifecycle façade with `--json`, `--quiet`, and
`--progress` output selection. `moon sync --progress plain` and `moon orbit
sync --progress plain` now emit durable revisioned task transitions to stderr.
Plain completion output has no terminal cursor control sequences.

The command audit found no other CLI command family currently scheduling work
through `realization.Scheduler`; registry/index/store operations remain serial.
Future Phase 3 adoption therefore begins when one of those commands gains
bounded concurrent work, rather than adding a second orchestration path early.

Phase 4 now has its first in-process slice: `RocksPool` claims prepared source
materialization through `realization.request_coordinator`, keyed by the
canonical recipe hash rather than package display names. Followers reuse their
leader's candidate result. The LuaRocks materializer still takes the existing
recipe-file lock before checking/reusing the CAS, so in-process coordination
reduces duplicate work without weakening cross-process correctness.

The next slice claims preparation before fetching or unpacking. Its
pool-scoped request hash covers the resolved registry source, package/version,
runtime, runtime artifact, and target. One leader owns the private
`PreparedRock` workspace; followers do not share that workspace and instead
reuse the leader's binary or materialized candidate. This keeps the ownership
boundary explicit while removing duplicate preparation work for identical
resolved requests.
