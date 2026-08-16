# LuaRocks Rockspec Compatibility Plan

## Purpose

Moonstone does not seek LuaRocks command-line parity. It does seek meaningful
rockspec compatibility: a valid LuaRocks rockspec is valid Moonstone input,
and Moonstone should produce the same observable package behavior whenever the
rockspec can be materialized without undeclared host assumptions.

`moonstone.toml` and `moonstone.lock` remain Moonstone-owned contracts. A
rockspec is external package input, not a second project model.

## Compatibility ladder

| Level | Claim | Required evidence |
| --- | --- | --- |
| P0 — Parse | Moonstone accepts valid rockspec source and preserves every declared field. | Pinned upstream fixture corpus, complete document projection, malformed-source rejection. |
| P1 — Validate and resolve | Moonstone applies equivalent rockspec-format validation and resolves the same dependency/source intent. | Versioned validator conformance and normalized dependency/source projections. |
| P2 — Materialize | For supported build backends, Moonstone produces an equivalent artifact interface. | Module, binary, patch, install-layout, and ABI artifact manifests. |
| P3 — Execute | The materialized package imports, native-loads, and executes equivalently in its declared runtime scope. | Runtime-specific import, binary, and C-module probes. |
| P4 — Replay | The materialized result reproduces from Moonstone's lock and artifact contracts. | Offline/replay tests after project-local environment removal. |

The levels are cumulative. Passing P0 never implies P2 or P4.

## P0 contract

P0 is intentionally broad and narrowly scoped:

- Moonstone evaluates declarative rockspec source in an isolated Lua bridge.
- The bridge emits a complete JSON-compatible `document`, independent of
  Moonstone's current resolver/build subset.
- The existing normalized resolver projection remains available for supported
  source and build paths.
- Lua syntax errors are rejected.
- A declaration that Moonstone cannot yet materialize is retained rather than
  discarded or silently rewritten.

P0 does not promise that Moonstone rejects every semantically invalid rockspec
in exactly the same way as LuaRocks. That becomes P1, where the versioned
LuaRocks rockspec schema and its validation behavior are made explicit.

## Materialization limits

P2+ must not treat a partial result as equivalent. A valid rockspec can be
accepted at P0/P1 yet remain non-materializable for a declared reason, such as:

- an unsupported build backend or hook behavior;
- hard-coded host installation paths;
- an undeclared compiler, system package, or external program;
- a non-relocatable deployment layout;
- source/build behavior that observes host state outside Moonstone's projected
  environment.

Each condition needs a stable capability diagnostic. The resolver must never
silently fall back to host-global behavior merely to claim compatibility.

## Stage plan

### Stage 1 — P0 parser preservation

1. Replace field-selective bridge serialization with complete document output.
2. Keep a separate normalized projection for the existing resolver.
3. Pin every upstream `.rockspec` fixture at a recorded LuaRocks revision.
4. Add a Moonstone schema-surface fixture for legal declaration fields absent
   from upstream fixtures.
5. Assert expected parse acceptance, syntax rejection, JSON validity, and
   complete-document preservation in local and CI tests.

### Stage 2 — P1 validation and resolution

**Current foundation:** the bridge emits `moonstone:luarocks-intent:v1`, a
platform-selected projection that applies LuaRocks' least-to-most-specific
override order. It remains separate from the raw `document` and is covered for
Linux and Windows selectors in the parser corpus. The bridge now also rejects
unknown rockspec-format versions with `UnsupportedRockspecFormat` and emits a
versioned validation envelope for accepted declarations. Its first field-level
slice enforces version-aware root fields, required package/source declarations,
and the declarative source, description, dependency, external-dependency,
build, test, hook, and deploy structures. Exact dependency-string grammar and
legacy-versus-namespaced dependency rules are now enforced; the remaining
LuaRocks diagnostics are still pending. Moonstone's LuaRocks resolver now
consumes the typed `RockspecIntent` projection for classification, source
fetching, build translation, binary discovery, and runtime dependency edges.
The bridge platform is selected from the requested Moonstone target profile
rather than always from the resolver host, so platform-specific dependency
arrays influence both PubGrub metadata discovery and stored dependency edges
for that profile; the complete document is inspection-only. Bridge format and structural failures
cross the Zig boundary as `UnsupportedRockspecFormat` and
`InvalidRockspecSchema`, rather than collapsing into `RockspecParseError`.
When the pinned upstream checkout is available, the conformance harness now
also compares each fixture's accepted, syntax-rejected, or schema-rejected
outcome against LuaRocks' own persisted-rockspec loader and versioned schema.
Moonstone follows that executable behavior where it is more permissive than
the declared schema; for example, LuaRocks accepts non-string entries in
`description.labels`, so Moonstone preserves the labels table rather than
rejecting those declarations.
The typed intent also applies LuaRocks' legacy CVS source normalization after
platform projection: `cvs_module` overrides `module`, `cvs_tag` overrides
`tag`, and an omitted `dir` defaults to the effective module name.

1. Define the supported LuaRocks rockspec-format versions.
2. Port or isolate versioned schema validation without requiring LuaRocks CLI
   execution during normal Moonstone resolution.
3. Test valid/invalid acceptance and diagnostics against the pinned upstream
   parser corpus.
4. Project dependencies, platform sections, and sources into a normalized
   resolver intent and compare it to the LuaRocks interpretation.

### Stage 3 — P2 materialization equivalence

**Current foundation:** `RockspecIntent` now carries the normalized build
declaration into the resolver, which rejects artifact-affecting declarations
that Moonstone would otherwise omit. See
`docs/maintenance/luarocks-materialization-equivalence-audit-2026-08-08.md`.

1. Inventory build backend, patch, install, external-dependency, hook, and
   deployment capabilities.
2. Define a normalized artifact manifest: Lua modules, C modules, binaries,
   copied files, generated files, ABI, and source provenance.
3. Certify supported rockspec families against that manifest.
4. Add explicit unsupported capability diagnostics for the rest.

`build_dependencies` use a separate target-aware, non-projectable `build`
closure. Moonstone materializes the closure before the dependent foreign build,
projects its binaries and Lua paths only into that build process, and includes
the resolved identities in the dependent recipe/replay contract. The closure
never becomes a runtime edge or appears in the final project environment.

The first reusable primitive for that closure now lives in
`src/core/project/build_scope.zig`. It accepts an ordered list of already
materialized artifact `files/` roots and returns an owned process environment:
artifact `bin`, Lua source, Lua C-module, and native-loader paths are projected
ahead of the inherited host environment. Missing output directories are not
invented, the source environment remains unchanged, and the scope never writes
or links `.moonstone/env`. `run_env.zig` and the build scope share the same
compile-time platform rules for path separators, Lua module extensions, and
native loader variables through `project/environment.zig`.

The scheduler realizes dependency-ready source Rocks in concurrent waves:
build-only prerequisites complete before their dependent foreign build, while
unrelated Rocks remain eligible for the same earlier wave. The
`tests/e2e/build/luarocks_build_dependencies_contract.sh` contract proves this
alongside projected-build isolation and locked replay.

### Stage 4 — P3 execution and P4 replay

1. Probe imports, native loading, and binaries in isolated runtime scopes.
2. Re-run the same probes from replayed/offline lock environments.
3. Publish compatibility statuses per fixture and backend rather than a single
   undifferentiated LuaRocks-compatibility claim.

## Immediate implementation target

Stage 1 is the smallest valuable slice. It removes field loss at the parsing
boundary and gives later work a durable corpus and fixture vocabulary without
claiming that every valid rockspec already materializes identically.
