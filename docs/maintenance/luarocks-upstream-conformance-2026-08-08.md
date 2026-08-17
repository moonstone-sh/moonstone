# LuaRocks Upstream Conformance Corpus

**Status:** August 16, 2026.

## Purpose

Moonstone consumes LuaRocks rockspecs, but it is not a replacement for the
LuaRocks CLI. This corpus makes compatibility claims auditable by pinning every
upstream rockspec fixture and testing parsing first, then resolution and
materialization only where separate evidence exists.

## Pinned Source

| Field | Value |
| --- | --- |
| Repository | `https://github.com/luarocks/luarocks.git` |
| Revision | `665f160b4d0b79e85e66c6cc83e442d72eb40868` |
| Snapshot contract | `tests/upstream/luarocks/corpus.toml` |
| Verifier | `tests/upstream/luarocks/run_conformance.sh` |

The verifier hashes the checked-in snapshots. With
`LUAROCKS_UPSTREAM_DIR` set, it also checks the source checkout revision and
byte-compares each snapshot to its upstream fixture.

## Certification Levels

| Level | Evidence | Public claim allowed |
| --- | --- | --- |
| P0 — Parse | Moonstone's isolated bridge preserves the complete declaration document | Moonstone accepts this rockspec input |
| P1 — Resolve | A normalized dependency/source projection matches the declared rockspec intent | Moonstone resolves this rockspec shape |
| P2 — Materialize | A normalized artifact interface matches the supported build result | Moonstone materializes this rockspec shape |
| P3 — Execute | The package imports, native-loads, or executes in Moonstone's runtime scope | Moonstone runs this rockspec shape |
| P4 — Replay | The same artifact behavior succeeds from a replayed lock environment | Moonstone reproduces this rockspec shape |

Only the final applicable level is a compatibility guarantee.

## Current Fixture Matrix

| Corpus input | Coverage | Current level | Next evidence |
| --- | --- | --- | --- |
| All 25 LuaRocks `spec/fixtures/**/*.rockspec` files plus Moonstone validation fixtures | Exact byte snapshot, expected parser outcome, and accepted fixtures projected across Linux/macOS/Windows | P0 + bounded P1 | Per-feature materialization capability inventory |
| Moonstone `format-3.1-surface.rockspec` | Source, description, dependency classes, build, test, hooks, deployment | P0 | Per-feature materialization capability inventory |
| LuaFileSystem `1.9.0-1` | Pinned official rockspec and `.src.rock`, builtin native module, copied assets, runtime filesystem behavior, and locked replay through a verified local mirror | P2/P3/P4 on the native Lua 5.4 target; CI-gated | `tests/e2e/resolution/luafilesystem_real_contract.sh` with `MOONSTONE_REAL_LUAROCKS=1` |
| LuaSQL SQLite3 `2.8.0-1` | Pinned official rockspec and `.src.rock`, builtin native module linked through caller-projected `SQLITE_INCDIR` and `SQLITE_LIBDIR`, copied docs, SQL runtime behavior, and locked replay through a verified local mirror | P2/P3/P4 where the host provides the declared SQLite SDK; CI-gated | `tests/e2e/resolution/luasql_sqlite3_real_contract.sh` with `MOONSTONE_REAL_LUAROCKS=1` |
| luv `1.51.0-1` | Pinned official rockspec and `.src.rock`, LuaRocks CMake variable map, bundled libuv native module, projected Lua runtime behavior, and locked replay through a verified local mirror | P2/P3/P4 where CMake and a native C toolchain are available; CI-gated | `tests/e2e/resolution/luv_real_contract.sh` with `MOONSTONE_REAL_LUAROCKS=1` |
| luaposix `36.3-1` | Pinned official rockspec and source ZIP, LuaRocks command backend placeholders, generated Lua/native POSIX modules, projected runtime behavior, and locked replay through a verified local mirror | P2/P3/P4 on supported POSIX hosts with a C compiler; CI-gated | `tests/e2e/resolution/luaposix_real_contract.sh` with `MOONSTONE_REAL_LUAROCKS=1` |
| cqueues `20200726.54-0` | Pinned official rockspec and source archive, Makefile/target/variable-map translation, `source.dir`, source MD5 verification, declared OpenSSL/crypto host paths, projected runtime behavior, and locked replay through a verified local mirror | P2/P3/P4 on supported GNU/Linux hosts with a C compiler and declared OpenSSL SDK; CI-gated | `tests/e2e/resolution/cqueues_real_contract.sh` with `MOONSTONE_REAL_LUAROCKS=1` |

Moonstone's existing synthetic scenarios already certify related, but not
upstream-fixture-identical, behavior for builtin native modules, Make builds,
transitive dependencies, binaries, and offline lock replay. They do not raise
the P1 resolver-intent boundary into a P2 materialization claim until each
claim uses a pinned upstream fixture or another explicitly versioned
compatibility fixture.

## Explicit Exclusions

The following upstream suite areas are not Moonstone conformance targets:

- `luarocks` CLI argument behavior and output;
- rock trees, `path`, `config`, and activation behavior;
- admin, upload, pack, purge, and server administration commands;
- LuaRocks internal Lua module APIs;
- `luarocks test` backends as a task runner contract.

Moonstone may interoperate with outputs from some of these features, but that
is a separate contract.

## Running the Corpus

```bash
LUA_BIN=luajit tests/upstream/luarocks/run_conformance.sh
```

To prove source provenance against an upstream checkout at the pinned commit:

```bash
LUAROCKS_UPSTREAM_DIR=/path/to/luarocks \
  LUA_BIN=luajit tests/upstream/luarocks/run_conformance.sh
```

CI installs Lua 5.4 and `jq`, then runs the same bridge corpus.

## Next Promotion Slice

P1 now has a bounded cross-platform projection differential. LuaFileSystem
`1.9.0-1` is the first real upstream P2/P3/P4 promotion: the test verifies the
official release bytes before serving them from a local mirror, then proves
the resulting `lfs` native module and copied asset closure survive locked
replay. LuaSQL SQLite3 `2.8.0-1` extends that claim to an explicit LuaRocks
external dependency: Moonstone projects caller-provided `*_INCDIR` and
`*_LIBDIR` values without shell evaluation and uses the host SDK/toolchain for
the declared SQLite headers and library. luv `1.51.0-1` extends the claim to
the CMake backend: Moonstone translates LuaRocks' documented variable map into
typed CMake definitions, keeps the install root disposable, and promotes only
the declared native module. luaposix `36.3-1` extends the claim to the command
backend: Moonstone resolves LuaRocks' documented `$(VARIABLE)` placeholders
into projected runtime and toolchain values before invoking the upstream shell
command, without asking the shell to perform LuaRocks configuration expansion.
For supported command and Make adapters, the normalized argv sequence and
declared collection rules now participate in the materialization recipe hash;
changing an adapter argument, projected external path, or collected output
cannot reuse a recipe identity from the old configuration.
Each fixture skips, rather than pretends conformance, when its required host
capability is unavailable. The typed Make adapter's cqueues contract is
certified on Linux CI: it translates declared makefiles, targets, variable
maps, and external path declarations without discovering or provisioning
OpenSSL itself. cqueues does not support macOS, so its claim remains bounded
to supported GNU/Linux hosts with the declared native capability.
