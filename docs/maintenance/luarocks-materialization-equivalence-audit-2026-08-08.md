# LuaRocks Materialization Equivalence Audit

## Scope

This audit defines the current P2 boundary for LuaRocks rockspecs. Moonstone
may accept and resolve a declaration at P0/P1 while refusing to materialize it
when the declared artifact interface cannot yet be reproduced faithfully.

The resolver's authoritative materialization input is
`RockspecIntent` in `src/core/luarocks/rockspec.zig`. It is derived from the
platform-normalized bridge projection and consumed by
`src/core/resolution/sources/luarocks.zig`.

## Current Artifact Interface

Moonstone commits a content-addressed output directory plus a recipe/source
record. Its observable package interface is:

- Lua module provisions;
- native Lua C-module provisions and their runtime ABI;
- executable provisions under `bin/`;
- dependency edges, source provenance, target, runtime artifact hash, recipe
  hash, and artifact hash.

The current construction paths are `translateBuiltinBuild`,
`translateCommandBuild`, `copy_bins`, `build_lua_module_list_from_translated`,
`build_c_module_list`, and `commit_synthetic_artifact` in
`src/core/resolution/sources/luarocks.zig`.

## Certified Candidate Families

| Rockspec family | Current artifact behavior | Certification | Evidence |
| --- | --- | --- | --- |
| builtin pure Lua modules, including mapped `build.install.lua`, and `install.bin` | Declared module paths and executables become provisions; the result survives locked replay | P2/P3/P4 certified within the documented boundary | `tests/e2e/materialization/luarocks_pure_lua_contract.sh`, `tests/e2e/materialization/luarocks_install_lua_contract.sh` |
| builtin C modules | Declared native sources become ABI-bound C-module provisions; the result survives locked replay | P2/P3/P4 certified on the current native target | `tests/e2e/build/luarocks_builtin_cmodule_contract.sh` |
| builtin Lua files and `install.bin` | Lua files and executables become provisions | Candidate; superseded by the focused pure-Lua contract above | `tests/e2e/materialization/luarocks_bin.sh` |
| Make build into Moonstone's standard Lua roots | Declared Make build inherits the projected compiler/runtime environment and its installed module is discovered as a provision | P2/P3/P4 certified for the bounded native-target C-module layout | `tests/e2e/build/luarocks_make_cmodule_contract.sh` |

A family is certified only when a versioned local or upstream fixture proves
the normalized artifact manifest and runtime behavior together.

## Explicit Materialization Refusals

Moonstone must not silently omit declarations that change the installed
artifact or observe host state. The resolver currently rejects:

| Declaration | Error | Reason |
| --- | --- | --- |
| `external_dependencies` | `UnsupportedLuaRocksExternalDependencies` | Host libraries/programs need an explicit provisioning contract. |
| `hooks` | `UnsupportedLuaRocksHooks` | Post-install commands are host-mutating behavior, not declarative artifacts. |
| `build.patches` | Ordinary unified modifications are applied before compatibility transforms and included in `moonstone:recipe:v3` as a canonical patch-transform hash | Rename, create/delete, no-final-newline, malformed, and command-build patch forms remain rejected. |
| `build.copy_directories` | Declared directories copy into the immutable artifact closure as `asset` provisions under `assets/`; they are not runtime-projected | Certified for regular files and directories; symlinks and special entries remain rejected. |
| `build.install.conf` | Read-only keyed files copy into the immutable artifact closure as `asset` provisions under `assets/conf/`; they are not runtime-projected | Certified for regular files with safe relative source and destination paths. |
| `build.install.lib` | Bounded support | Regular shared libraries and static archives with target-recognized filenames become typed `native_lib` provisions; arbitrary layouts remain rejected. |
| `build.type = "command"` without `build_command` | `MissingLuaRocksBuildCommand` | Command rocks must explicitly declare their build shell body. |
| `build.type = "command"` without `install_command` | `MissingLuaRocksInstallCommand` | Command rocks must explicitly declare their install shell body. |
| unrecognized `build.type` | `UnsupportedLuaRocksBuildType` | Moonstone cannot claim equivalence for an unimplemented LuaRocks build backend. |

The raw rockspec document remains preserved for inspection even when one of
these capability checks rejects materialization.

`tests/e2e/materialization/luarocks_capability_refusals.sh` drives each listed
declaration through the normal local LuaRocks HTTP boundary and asserts the
stable capability error. This keeps parser acceptance separate from the later
artifact-equivalence claim.

## GitHub VCS Source Selection Boundary

When a published `.src.rock` is unavailable, the source selector maps
`git://github.com/<owner>/<repo>.git` and
`git+https://github.com/<owner>/<repo>.git` declarations to GitHub archive
URLs. A declared tag selects `refs/tags/<tag>`; otherwise the declared branch,
or `master` when absent, selects `refs/heads/<branch>`. The pure selection rule
is covered in `src/core/resolution/sources/luarocks.zig` without introducing a
general Git client, shell-out, or VCS transport fallback.

This is source-selection behavior, not a certification of arbitrary VCS
materialization. The P2/P3/P4 artifact claim remains limited to a fetched
archive or published `.src.rock`, with ordinary checksum, extraction, and
declared-output guarantees.

## Certified Pure-Lua Slice

`tests/e2e/materialization/luarocks_pure_lua_contract.sh` uses a local,
versioned source-rock fixture. It modifies the fixture only to declare the same
Lua source as both `modules.fake` and `install.bin.fakebin`, then proves:

1. the committed artifact manifest contains the expected Lua-module and binary
   provisions plus source, recipe, and artifact identities;
2. `moon exec` projects the module through `LUA_PATH` and exposes the binary on
   `PATH`;
3. removing both the CAS artifact and `.moonstone/env` followed by
   `moon sync --locked` restores the same provision interface and runtime
   behavior.

This is a P2/P3/P4 guarantee for the bounded builtin pure-Lua and executable
case. It does not certify arbitrary LuaRocks build layouts or host-dependent
build behavior.

## Certified `source.dir` Slice

`tests/e2e/materialization/luarocks_source_dir_contract.sh` serves an archive
whose package sources live below `source.dir = "nested"`. It proves that
Moonstone selects that directory after ordinary archive-root selection,
interprets builtin module and executable paths relative to it, and recreates
the same behavior with `moon sync --locked` after removing the artifact and
environment.

`source.dir` is limited to a relative, non-symlink directory below the
extracted package root. Unsafe or missing values fail explicitly; the archive
hash remains the source identity while the selected directory defines the
build workspace.

The same fixture uses an extensionless source URL with
`source.file = "source-dir-rock-0.1.0.tar.gz"` and a valid `source.md5`.
Moonstone uses `source.file` solely to choose the archive decoder and verifies
the legacy checksum before extraction; it retains the fetched URL and BLAKE3
payload hash as its provenance and lock identities.

`supported_platforms` is a resolution boundary rather than a build instruction.
Moonstone compares it with the platform selected for the target profile before
fetching source; `unix` matches Linux, macOS, and other non-Windows LuaRocks
platforms. A no-match returns `UnsupportedLuaRocksPlatform` instead of
materializing an artifact the rockspec declares unsupported.

`build.install.bin` is now also a typed flat-executable contract for
declarative builtin rocks: keyed names and array basenames must be safe
portable executable names, source values must be regular files beneath source
root without symlink traversal, and duplicate artifact destinations fail before
copying. The sorted binary provisions are included in the recipe identity, so
file copying, artifact metadata, and locked replay use the same declaration
set. Command-build backends use the same declarations as an explicit
post-build output manifest: Moonstone runs the foreign build, validates only
the declared generated paths, and never sweeps arbitrary build-tree files.
Invalid names and paths are covered by
`tests/e2e/materialization/luarocks_capability_refusals.sh`.

## Certified `build.install.lua` Slice

`tests/e2e/materialization/luarocks_install_lua_contract.sh` serves a source
rock that uses LuaRocks' mapped install form:

```lua
build = {
   install = {
      lua = { ["nested.greeting"] = "src/greeting.lua" },
   },
}
```

Moonstone follows LuaRocks' module-path rule: the dotted key provides the
logical module name and destination path, while the source file provides the
content. The test proves the resulting `lua_module` provision, projected
`require("nested.greeting")`, and locked replay after the CAS artifact and
project environment are removed.

Native library installation is covered by the bounded `build.install.lib`
contract below; configuration files remain covered by the separate
`build.install.conf` asset contract.

## Certified `build.copy_directories` Slice

`tests/e2e/materialization/luarocks_copy_directories_contract.sh` serves
source rocks with regular files under declared `doc` and `examples` directories,
plus a package with no `doc/` directory and root `README.md`/`LICENSE` files.
Moonstone records each copied file as an `asset` provision and stores it beneath
the immutable artifact's `assets/` root. The test then removes both stored
artifacts and project environments, runs `moon sync --locked`, and verifies
that the same asset records and file contents are reconstructed.

This follows LuaRocks' package-closure intent without treating documentation,
examples, or other copied files as Lua modules, C modules, or executables.
They remain queryable artifact metadata and deliberately do not alter
`PATH`, `LUA_PATH`, or `LUA_CPATH`.

The certified boundary is regular files inside real directories. Symlinks and
special filesystem entries fail explicitly so a source package cannot smuggle
an external filesystem reference into a content-addressed artifact. The
default LuaRocks `doc` directory is copied when present; an explicitly declared
missing directory remains an error. Native libraries use the separate bounded
`build.install.lib` contract because loader projection requires target-aware
shared/static classification.

## Certified `build.install.conf` Slice

`tests/e2e/materialization/luarocks_install_conf_contract.sh` serves a
self-contained source rock over the normal LuaRocks HTTP boundary. It proves:

1. keyed `build.install.conf` entries retain LuaRocks' destination layout under
   Moonstone's inspectable `assets/conf/` closure;
2. those files do not become Lua modules or otherwise alter runtime projection;
3. removing the CAS artifact and `.moonstone/env` followed by `moon sync
   --locked` reconstructs the same configuration asset closure.

Moonstone accepts array entries as basename-preserving files and keyed entries
as explicit relative destinations. Symlinks, special files, unsafe paths, and
destination collisions are rejected.

## Certified `build.install.lib` Slice

`tests/e2e/materialization/luarocks_install_lib_contract.sh` serves one keyed
shared-library rock and one array static-archive rock across the normal
LuaRocks HTTP boundary. It proves that Moonstone:

1. maps a keyed declaration such as `native.installlib = "native/libfoo.so"`
   to `lib/native/native/installlib/libfoo.so`, preserving the source basename
   and recording it as a `native_lib` provision;
2. maps an array entry to `lib/native/<source-basename>`;
3. classifies `.so`/`.so.*` (Linux and FreeBSD), `.dylib` (macOS), and `.dll`
   (Windows) as shared, and `.a`/`.lib` as static for the concrete target;
4. projects shared libraries into `.moonstone/env/lib/native` while keeping
   static archives in the immutable artifact only; and
5. reconstructs the same provisions and projection through `moon sync --locked`
   after the artifacts and project environment are removed.

The boundary remains intentionally narrow. It applies to declarative builtin
rocks, not `make`, `command`, or other command-build backends whose outputs do
not exist until after foreign orchestration. Values must be regular files below
source root without symlinks, keys must be dotted module-like identifiers with
ASCII alphanumeric, `_`, or `-` segments, and two shared libraries cannot share
a loader-visible basename. Moonstone does not inspect binary formats, patch
rpaths/install names, infer a foreign library type, or promise cross-target
execution. Unsupported target/filename pairs fail explicitly instead of being
misclassified as Lua C modules.

## Certified Builtin C-Module Slice

`tests/e2e/build/luarocks_builtin_cmodule_contract.sh` builds a minimal local
source rock through the same HTTP boundary used by the resolver. It proves:

1. the committed artifact manifest records a native target, `lua_abi = "5.4"`,
   BLAKE3 source/recipe/artifact identities, and the expected C-module
   provision;
2. the projected Lua 5.4 runtime loads the compiled module and observes its
   exported behavior;
3. removing both the CAS artifact and `.moonstone/env` followed by
   `moon sync --locked` rebuilds the artifact with the same ABI-facing
   provision and runtime behavior.

This is a P2/P3/P4 guarantee for the bounded builtin C-module case on the
current native target. Cross-target C-module equivalence and command-build
replay remain separate certification work.

## Certified Make C-Module Slice

`tests/e2e/build/luarocks_make_cmodule_contract.sh` serves a self-contained
source rock over the normal LuaRocks HTTP boundary. Its `Makefile` installs a
single native module into Moonstone's documented
`$PREFIX/lib/lua/$LUA_ABI` root. The test proves:

1. discovery records that installed module as an ABI-bound `lua_cmodule`
   provision with source, recipe, and artifact identities;
2. post-build `build.install.bin` and `build.install.lib` declarations become
   typed executable and shared-library provisions;
3. generated `build.copy_directories` and keyed `build.install.conf` entries
   become inspectable, non-projected asset provisions;
4. the projected Lua 5.4 runtime imports and executes the module;
5. removing both the CAS artifact and `.moonstone/env` followed by
   `moon sync --locked` rebuilds the same closure and runtime behavior.

This is a P2/P3/P4 guarantee for a Make backend that installs into Moonstone's
standard Lua module roots and declares generated executable, native-library,
copied-directory, and configuration-file outputs through `build.install.bin`,
`build.install.lib`, `build.copy_directories`, and `build.install.conf` on the
current native target. Moonstone validates and collects only those explicit
output paths after the foreign build completes. It does not certify arbitrary
Makefiles, host toolchains, undeclared outputs, symlinked assets, or
cross-target native builds.

## CMake Declared-Output Boundary

The CMake adapter reuses the same post-build declaration collector as the Make
and command backends, but installs first into `.moonstone-cmake-install`, a
disposable staging prefix below the output workspace. A CMake project may
declare staged executables, native libraries, copied directories, and
configuration assets through `build.install.bin`, `build.install.lib`,
`build.copy_directories`, and `build.install.conf`. Moonstone promotes only
those typed paths after CMake completes; it never sweeps the CMake build tree
or leaves the install staging directory in the committed closure.

## Certified Command-Backend Slice

`tests/e2e/build/luarocks_command_contract.sh` serves a source rock with no
`Makefile`. Its `build.type = "command"` declaration supplies the LuaRocks
`build_command` and `install_command` shell bodies. On POSIX hosts Moonstone
executes each through non-interactive `sh -c` after projecting the runtime,
output-root, and compiler environment. The fixture proves that:

1. shell chaining creates the declared copied-directory and configuration
   assets in the source tree;
2. the shell bodies see `PREFIX`, `LUA_ABI`, `LUA_INCDIR`, `LUA_LIBDIR`, and a
   runnable `LUA_BINDIR/lua`; the fixture records a stable declared report,
   then installs a Lua module while generating a declared executable;
3. Moonstone records only the declared Lua-module, executable, and asset
   provisions; and
4. deleting the stored artifact and project environment followed by
   `moon sync --locked` reconstructs the same closure and runtime behavior.

This certifies the bounded command-backend contract for POSIX hosts. It does
not certify arbitrary shell availability, Windows command syntax, command
strings with host-provisioned dependencies, undeclared outputs, or
cross-target native builds.

## Certified CMake Slice

`tests/e2e/build/luarocks_cmake_contract.sh` serves a conventional CMake
source rock that installs one Lua C module with `install(TARGETS ...)`. The
adapter configures CMake with Moonstone's Lua header path, `LUA_ABI`, and an
isolated install prefix; it builds in `.moonstone-cmake-build` beneath the
disposable source workspace, then executes `cmake --install`. The fixture
proves that:

1. the generated build tree is excluded from the committed artifact closure;
2. the installed module is discovered as an ABI-bound `lua_cmodule` provision;
3. CMake-installed `build.install.bin`, `build.install.lib`,
   `build.copy_directories`, and keyed `build.install.conf` declarations become
   one executable, one target-aware shared native-library provision, and two
   inspectable asset provisions without scanning unrelated outputs;
4. the projected runtime loads and executes the module and the generated
   executable; and
5. deleting the CAS artifact and project environment followed by
   `moon sync --locked` recreates the same closure and runtime behavior.

This certifies standard CMake-installed Lua C modules plus declared installed
executables, native libraries, and assets on the current native target. It does
not certify ambient CMake generators, `find_package` host dependencies,
undeclared install-prefix contents, or cross-target native builds.
