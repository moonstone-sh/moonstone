# Parallel Realization, CLI Manager, and NDJSON Task Protocol

## Why These Changes Are One System

LuaRocks source realization is moving from inline work during dependency solving
to a bounded post-solve scheduler. That turns package work from a single linear
operation into concurrent task lifecycles. A worker-owned spinner or direct
stdout write cannot represent that safely: workers race for terminal rows,
machine consumers lose causal task identity, and cancellation/failure output
becomes nondeterministic.

Moonstone therefore needs one shared boundary:

```text
solver and materializers
  -> structured task updates
  -> scheduler task state
  -> CLI manager
  -> fancy terminal | plain text | quiet exit code | NDJSON
```

The scheduler owns task execution; the CLI manager owns all display rows,
cursor movement, global event ordering, and machine-output serialization.

## Implemented Foundation

- `src/core/resolution/sources/luarocks.zig` now exposes
  `query_runtime_dependencies`. It fetches and validates one selected
  rockspec, then projects dependency terms without fetching sources, invoking
  a materializer, or writing the CAS. `graph_provider.zig` uses it for
  transitive dependency discovery.
- `src/core/luarocks/rockspec.zig` now uses a unique workspace beneath
  Moonstone's configured temporary root for every parser invocation. It no
  longer races through a shared `/tmp` directory and does not assume a POSIX
  temp path.
- `src/core/realization/scheduler.zig` provides bounded generic workers,
  fail-fast error propagation, and cancellation checks. `sync` now uses it for
  registry materialization instead of owning another execution loop.
- `src/cli/progress.zig` accepts task ids plus monotonic revisions. Its display
  manager is the only component that owns terminal rows; workers submit state
  updates rather than printing their own spinners.
- `src/cli/commands/ndjson.zig` emits serialized
  `moonstone:cli-events:v1` envelopes with a run id and idempotent task-state
  events. `moon sync` exposes `--jobs`, `--progress`, and `--quiet` alongside
  the existing `--json` surface.
- `src/core/store.zig` serializes publishers for a content-addressed artifact
  through a cross-process advisory lock, assembles a complete staging
  directory beside the final store path, then atomically renames it into
  place. SQLite registration happens only after publication.
- Fresh `moon sync` prescans the accepted solution for LuaRocks source
  requests, realizes them through the same bounded scheduler as remote
  registry artifacts, then replaces the request candidates before lock and
  projection serialization. PubGrub no longer builds fresh LuaRocks packages
  while extracting its solution.

## Remaining Integration

- PubGrub still asks `PackageProvider.getArtifact` while extracting its
  answer, but fresh LuaRocks requests now return lightweight source candidates
  and are scheduled after the complete solution has been accepted. Locked
  replay temporarily retains its exact-artifact realization path; migrate it
  only after preserving its stricter hash diagnostics.
- The scheduler has a bounded queue but not yet a request-keyed in-flight map.
  Add one keyed by canonical source and recipe inputs rather than package
  names alone, then use a compatible cross-process recipe lock before source
  build work starts.
- Locked replay and source realization still need to emit the same lifecycle
  events and use the same scheduler pathway as remote registry downloads.
- Cross-device promotion still relies on the existing fallback outside the
  atomic rename path. Replace that fallback with a platform-native recursive
  copy implementation before advertising cross-volume publication as atomic.

## Target Contract

### Resolution and realization

1. Parse and validate a rockspec into `RockspecIntent` to obtain dependency
   terms without running a materializer or writing to the CAS.
2. Let PubGrub select the complete solution.
3. Submit accepted source packages to a resolver-neutral realization scheduler.
4. Materialize only after the selected runtime is available.
5. Publish through a per-recipe lock, staging directory, complete-artifact
   recheck, and atomic winner selection.

The initial scheduler adoption is LuaRocks. The scheduler remains generic so
Moonstone registry, path, and link sources can adopt it later.

### Task and output protocol

Every scheduled task has:

- a stable request-derived `task_id`;
- a monotonic `revision` for idempotent state replacement;
- a canonical recipe/realization identity once source and materializer inputs
  are known;
- one state: `queued`, `running`, `reused`, `completed`, `failed`, or
  `cancelled`.

Workers send structured state updates only. The CLI manager assigns global
sequence numbers and is the sole owner of terminal rows and NDJSON writes.
Tasks provide status, byte progress, warnings, and optional bounded detail;
they never request terminal lines.

### Sync output modes

`moon sync` exposes:

- `--jobs N`: positive worker limit; omitted defaults to
  `min(available CPUs, 8)`, with floor `1`;
- `--progress fancy|plain|auto`: human renderer selection;
- `--quiet`: no stdout/stderr, including failure diagnostics; exit code only;
- `--json`: `moonstone:cli-events:v1` NDJSON on stdout and no human progress.

`--json` is incompatible with explicit human progress selection and `--quiet`.

## Delivery Order

1. Add the command/output contract, event fields, and focused CLI tests.
2. Extract non-materializing LuaRocks metadata discovery and use it for solver
   dependency terms.
3. Introduce scheduler task state, bounded workers, cancellation, and unified
   progress updates.
4. Harden CAS commit publication for same- and cross-process realization
   deduplication. **The final-artifact lock and staged publish are complete;
   source-recipe coordination and cross-device copy remain.**
5. Route fresh and locked LuaRocks realization through the scheduler.
6. Migrate Moonstone registry downloads to the shared task protocol. **The
   remote download pool already uses the scheduler and task protocol.**

## Certification

The change is complete when solver-only LuaRocks discovery creates no artifacts,
backtracked candidates are never built, duplicate accepted requests materialize
once, concurrent processes leave one valid CAS artifact, `--jobs 1` remains
serial, and fancy/plain/quiet/NDJSON each preserve their stated output
contract.
