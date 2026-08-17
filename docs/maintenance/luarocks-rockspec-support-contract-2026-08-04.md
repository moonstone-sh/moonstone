# LuaRocks Rockspec Support Contract

**Status:** August 16, 2026. This document describes the support boundary that
Moonstone currently tests. It is a contract for project authors, not a claim of
full LuaRocks compatibility.

## Guaranteed and Certified

| Rockspec shape | Moonstone behavior | Certification |
| --- | --- | --- |
| `build.type = "builtin"` or omitted, pure Lua modules | Fetch, resolve, materialize Lua files | Resolver and offline-rock scenarios |
| `build.install.bin` | Materialize validated flat executable provisions from regular source files beneath the package root | `tests/e2e/materialization/luarocks_pure_lua_contract.sh`, `tests/e2e/materialization/luarocks_bin.sh` |
| `source.dir` | Select one validated relative subdirectory from the extraction root before interpreting build declarations; no archive-root duplication or traversal is permitted | `tests/e2e/materialization/luarocks_source_dir_contract.sh`, `tests/e2e/resolution/luaposix_real_contract.sh` |
| `source.md5` | Verify the fetched LuaRocks payload against its declared legacy checksum before extraction; retain BLAKE3 for Moonstone artifact identity | `tests/e2e/materialization/luarocks_capability_refusals.sh` |
| `source.file` | Use the declared payload filename to select the archive decoder when the source URL itself has no archive extension | `tests/e2e/materialization/luarocks_source_dir_contract.sh` |
| `supported_platforms` | Reject resolution before source fetching when the selected Moonstone target platform is not declared; `unix` matches non-Windows LuaRocks targets | `tests/e2e/materialization/luarocks_capability_refusals.sh` |
| mapped `build.install.lua` modules | Preserve LuaRocks dotted module keys in Moonstone Lua-module provisions and replay them from the lock | `tests/e2e/materialization/luarocks_install_lua_contract.sh` |
| `build.copy_directories` | Preserve declared package files as inspectable artifact assets under `assets/`; do not expose them through Lua or executable runtime paths | `tests/e2e/materialization/luarocks_copy_directories_contract.sh` |
| `builtin` C sources in `build.modules` | Translate to ABI-bound native C-module materialization, preserve declared assets, project the module at runtime, and reconstruct it from the lock | `tests/e2e/build/luarocks_builtin_cmodule.sh`, pinned LuaFileSystem `1.9.0-1` in `tests/e2e/resolution/luafilesystem_real_contract.sh` |
| declared `external_dependencies` include/library paths | Require every `-I$(NAME_INCDIR)` and `-L$(NAME_LIBDIR)` placeholder to be supplied in the projected build environment; include their exact values in recipe identity | pinned LuaSQL SQLite3 `2.8.0-1` in `tests/e2e/resolution/luasql_sqlite3_real_contract.sh` |
| `build.type = "make"` installing into Moonstone's Lua roots and declaring generated outputs | Translate to the command materializer, project the runtime/compiler environment, discover installed Lua modules, then collect only declared `install.bin`, `install.lib`, `copy_directories`, and `install.conf` outputs before locked replay | `tests/e2e/build/luarocks_make_cmodule_contract.sh` |
| `build.type = "command"` with `build_command` and `install_command` on POSIX hosts | Invoke each declared shell body through non-interactive `sh -c` in Moonstone's projected build environment, then collect only declared Lua, executable, copied-directory, and configuration outputs before locked replay | `tests/e2e/build/luarocks_command_contract.sh` |
| `build.type = "cmake"` with standard CMake install rules for Lua C modules and declared `install.bin`, `install.lib`, `copy_directories`, or `install.conf` paths | Configure with Moonstone's Lua headers, build in a disposable source-workspace directory, install into an isolated staging prefix, then promote only discovered Lua modules and explicitly declared typed outputs before locked replay | `tests/e2e/build/luarocks_cmake_contract.sh` |
| pinned cqueues `20200726.54-0` Make release on supported GNU/Linux hosts | Translate `source.dir`, source MD5, Makefile/target/variable-map declarations, and explicit OpenSSL paths; import the resulting native module and reproduce it from the lock | `tests/e2e/resolution/cqueues_real_contract.sh` in Linux CI |
| LuaRocks dependencies | Resolve transitively with explicit `rocks:` provenance | Transitive/offline resolver scenarios |
| Source archives | Handle zip, tar, gzip, bzip2, xz, and `.rock` archive forms when required host tools exist | Resolver/materialization scenarios |

## Bounded Build Environment

Moonstone translates the supported LuaRocks build declarations into typed
materializer configuration. It does not delegate package installation to the
LuaRocks CLI and it does not discover or provision host SDKs.

- `builtin`, Make, CMake, and command backends receive Moonstone's selected Lua
  runtime paths, target identity, and projected build environment.
- LuaRocks `$(VARIABLE)` references accepted by the command and Make adapters
  are resolved by Moonstone before process launch. They are exact documented
  configuration substitutions, not shell evaluation or arbitrary expansion.
- `external_dependencies` can declare a bounded host surface. Required
  `NAME_INCDIR` and `NAME_LIBDIR` values must be explicitly supplied by the
  caller environment; Moonstone neither searches the system nor installs a
  dependency manager's equivalent. LuaSQL SQLite3 is certified under this
  rule in `tests/e2e/resolution/luasql_sqlite3_real_contract.sh`.
- Command bodies remain owned by their declared LuaRocks backend. Moonstone
  does not parse foreign compiler flags or shell syntax.
- The normalized command sequence, its exact argv values, declared collection
  rules, projected build environment, runtime, and target participate in the
  materialization recipe identity. TOML formatting alone does not.

This is intentionally a reproducible build contract with explicit host inputs,
not a promise that every historical rock can build on every host.

## Implemented, Not Yet Certified as a Stable Guarantee

| Rockspec shape | Current implementation | Before guarantee |
| --- | --- | --- |
| Platform-specific rockspec branches | The bridge emits a `moonstone:luarocks-intent:v1` projection using LuaRocks' least-to-most-specific override order, selected from Moonstone's target profile | Versioned validation, target-specific dependency resolution, and resolver consumption of every platform-scoped field |
| arbitrary `external_dependencies` semantics | Bounded `NAME_INCDIR` / `NAME_LIBDIR` projection is implemented for supported build adapters; generic discovery, package-manager integration, and provisioners are absent | More upstream P2–P4 fixtures across host SDKs and targets |

## Deliberately Rejected

Unknown `build.type` values fail with `UnsupportedLuaRocksBuildType`. Moonstone
does not silently invoke LuaRocks itself as an opaque fallback, provision system
dependencies, or promise binary-rock compatibility without a materialization
and replay contract.

Moonstone refuses declarations that would otherwise be silently omitted from
its artifact closure: `hooks`. Ordinary `build.patches` unified modifications
are applied before materialization and
included in the recipe identity; rename, create/delete, and no-final-newline
patch forms remain explicitly unsupported. `build.install.conf` keyed files
are retained as non-projected package assets under `assets/conf/`. Bounded
`build.install.lib` declarations are accepted only for recognized native
shared-library and static-archive filenames for Moonstone's concrete target.
For `build.type = "command"`, both `build_command` and `install_command` are
required strings. Moonstone treats them as host-shell source: POSIX hosts use
non-interactive `sh -c`; Windows uses `cmd /d /s /c`. It does not parse or
translate their shell syntax, and Windows command-backend behavior remains
implemented but not yet certified by a native runtime fixture.

`build_dependencies` resolve into a separate target-aware, lock-replayable
build scope. Moonstone materializes that closure before the dependent Make,
command, or CMake build and projects its binaries and Lua paths only into that
foreign process. Build-only packages never become final runtime edges or appear
in the project environment. Dependency-ready source rocks materialize in
concurrent waves, so unrelated rocks remain eligible while a dependent build
waits for its declared prerequisites. The complete isolation, scheduling, and
locked-replay contract is covered by
`tests/e2e/build/luarocks_build_dependencies_contract.sh`.

The remaining explicit capability errors and rationale are recorded in
`docs/maintenance/luarocks-materialization-equivalence-audit-2026-08-08.md`.

## Provenance and Diagnostics

`moonstone.lock` remains the record of resolved source, artifact, target, and
realization facts. A rockspec is authoring input; its semantic build path must
be visible through resolution/materialization diagnostics and is only promoted
to a supported guarantee once it has a deterministic fixture.

## Pinned Upstream Corpus

`tests/upstream/luarocks/` pins every `.rockspec` fixture from LuaRocks
upstream revision `665f160b4d0b79e85e66c6cc83e442d72eb40868`, plus a
Moonstone-authored format-3.1 schema-surface fixture. The corpus is checked for
byte identity and evaluated through Moonstone's isolated bridge in CI.

This currently certifies **P0 parser preservation**, plus bounded **P1
validation and resolver-intent parity** for accepted fixtures across Linux,
macOS, and Windows selectors:

| Input | Certified interpretation | Not yet claimed |
| --- | --- | --- |
| All 25 pinned upstream fixtures | Expected-valid source yields a complete JSON-compatible declaration document; malformed Lua is rejected; accepted fixtures match LuaRocks' normalized resolver projection for source, dependency, build, hook, and test fields across Linux/macOS/Windows | LuaRocks command, build, install, or replay parity |
| `format-3.1-surface.rockspec` | Every versioned declaration family is retained, including source, descriptions, dependency classes, build, test, hooks, and deployment | Equivalent realization of each field |

The upstream LuaRocks suite cannot be run verbatim against Moonstone because it
also verifies LuaRocks' own CLI, trees, administration, packing, and internal
Lua modules. The corpus is therefore an auditable parser boundary, not a claim
that Moonstone is a LuaRocks CLI replacement. The complete P0–P4 ladder lives
in `docs/maintenance/luarocks-rockspec-compatibility-plan-2026-08-08.md`.

## Promotion Rule

To move an item into **Guaranteed and Certified**, add a local fixture that
proves parsing, resolution, materialization, lock replay, and failure diagnostics
for its target scope. Windows-specific paths additionally require the Windows
CI job to pass.
