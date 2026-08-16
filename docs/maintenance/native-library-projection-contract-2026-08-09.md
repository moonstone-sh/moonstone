# Native Library Projection Contract

## Purpose

Moonstone already stores `native_lib` provisions in artifact manifests and the
SQLite store index, but the project environment currently projects only
executables, Lua modules, and Lua C modules. `build.install.lib` from LuaRocks
cannot be supported honestly until an installed library has a deterministic,
target-aware runtime and tool-consumption contract.

This document records the bounded native-library boundary used when
`build.install.lib` is accepted.

## Current facts

- `manifest.FeatureProvision` already represents `native_lib` entries in
  `src/core/domain/manifest.zig`.
- `src/core/store/driver.zig` persists them in `provides_native_lib`.
- `src/core/project/linker.zig` projects selected runtime `provs.libs` into
  the root environment under `.moonstone/env/lib/native`.
- `src/core/project/run_env.zig` constructs `PATH`, `LUA_PATH`, `LUA_CPATH`,
  and a host-specific native-library search path.
- `moon exec` receives that projected environment from
  `src/cli/commands/exec.zig`.

Consequently, selected artifacts can expose native-library files to a child
process without Moonstone rewriting the binary's loader metadata. The
projection is deliberately narrower than a general native build contract.

## Contract v1

The root environment will project runtime-loadable native libraries into:

```text
.moonstone/env/lib/native/<provision-name>
```

Each entry is a link to the immutable artifact file, using the provision
path's basename—the loader-visible filename—not the provision's semantic name.
A project environment must reject two selected artifacts that provide the same
filename with different artifact identities. The filename is therefore the
project-visible conflict key, just as public binary names already are.

This projection is for selected runtime and production dependencies only. Tool
and helper isolation keeps its existing role policy; a tool may receive native
libraries through its scoped `bin-runtime` environment in a later explicit
extension rather than leaking them into the project root.

## Host-loader environment

Moonstone owns only the host-environment projection. It does not rewrite
install names, patch rpaths, inspect ELF/Mach-O/PE dependency graphs, or make a
foreign binary portable.

The `native_lib_path` is added using compile-time host-platform branches:

| Host family | Projection |
| --- | --- |
| Linux and FreeBSD | Prepend `LD_LIBRARY_PATH` |
| macOS | Prepend `DYLD_FALLBACK_LIBRARY_PATH` |
| Windows | Prepend `PATH` |

The branch is selected from Zig's `builtin.os.tag`, so a host executable does
not ship runtime selection logic for unsupported loader families. The existing
target model in `src/core/platform/target.zig` remains the persisted target
identity; loader projection is host execution behavior, not lock-profile
selection.

`DYLD_FALLBACK_LIBRARY_PATH` is intentionally a fallback rather than a claim
that Moonstone can override absolute install names, hardened runtime policy,
or an arbitrary `@rpath` graph. Those remain package build responsibilities.

## `build.install.lib` eligibility

LuaRocks maps keyed `build.install.lib` entries into an ABI-specific library
directory while retaining the source basename. Moonstone v1 accepts only
regular source files with:

- safe relative source paths;
- safe relative destination keys;
- a recognized native-library filename for the current concrete target;
- no symlinks, devices, directories, or special files;
- no conflicting destination library name in the selected project closure.

A keyed entry is copied to `lib/native/<dotted-key-as-path>/<source-basename>`;
an array entry is copied to `lib/native/<source-basename>`. Each is recorded as
a `native_lib` provision with `linkage = "shared"` or `linkage = "static"`.
Static archives are retained for compiler consumption but are not projected
into the runtime loader path. A later toolchain-facing contract can refine
native-link behavior without changing artifact storage.

## Explicit non-goals

- No rpath rewriting or binary post-processing.
- No automatic conversion of generic native libraries into `lua_cmodule`.
- No dynamic-link dependency scanning.
- No cross-target execution claim.
- No global library-directory mutation.
- No host fallback outside Moonstone's projected environment.

## Certification sequence

1. **Complete:** Link existing `native_lib` provisions into
   `.moonstone/env/lib/native`.
2. **Complete:** Add `native_lib_path` to `RunEnv`, `moon env`, shell exports,
   and `moon exec`.
3. **Complete:** Add host-specific unit tests for environment variable
   selection using compile-time platform branches.
4. **Implemented; pending the next Windows CI result:**
   `tests/e2e/commands/native_library_projection.sh` builds a
   real shared library and artifact-backed public binary, then proves the
   selected POSIX host resolves that library only through Moonstone's projected
   loader environment. `tests/windows/core.ps1` now builds a real DLL and a
   `LoadLibraryA` probe, publishes the pair into an isolated local registry,
   and proves that `moon exec` exposes the projected directory through Windows
   `PATH` when the `windows-latest` job runs. It is not simulated through Wine
   or a cross-built executable.
5. **Complete:** Translate bounded LuaRocks `build.install.lib` declarations
   into typed provisions, classify shared versus static output, and certify
   locked replay with `tests/e2e/materialization/luarocks_install_lib_contract.sh`.

The accepted slice preserves artifact identity, target classification, and
locked replay semantics rather than treating a generic installed file as
loader-safe.

## `build.install.lib` implementation boundary

Moonstone now distinguishes shared, static, and legacy-unknown native library
provisions. The Lua runtime already contributes `liblua.a`; retaining it in a
project artifact remains useful, but treating it as a runtime loader guarantee
would be wrong.

The provision classification is:

```text
native_lib.linkage = shared | static | unknown
```

Existing registry descriptors without the field remain `unknown` and preserve
their previous projection behavior. Explicitly `static` provisions remain
materialized and inspectable but do not enter `.moonstone/env/lib/native`.
Explicitly `shared` provisions remain loader-visible. The stored manifest,
SQLite index, artifact-store API, and recipe hash all retain this identity.
LuaRocks-derived provisions must always record `shared` or `static`.

The accepted `build.install.lib` slice applies to declarative builtin rocks and
to command-build rocks that declare their generated library path explicitly.
For command backends Moonstone runs the foreign build first, then validates and
collects only the declared path rather than sweeping arbitrary files. Within
that boundary it does the following:

1. accept only array entries and keyed string mappings;
2. resolve source files from the prepared source/build root with no symlink
   following and beneath-root enforcement;
3. reproduce LuaRocks' mapping rule in the artifact: an array entry keeps its
   source basename; a keyed entry uses the dotted key only as a safe logical
   subdirectory and still retains the source basename;
4. classify the retained basename against the concrete target vocabulary in
   `src/core/platform/target.zig`:
   `.dll`/`.lib` for Windows, `.dylib`/`.a` for macOS, and `.so` (including
   versioned `.so.*` names)/`.a` for Linux and FreeBSD;
5. reject all other filenames, unsafe keys, source directories, symlinks,
   special files, and duplicate loader-visible basenames with stable errors;
6. include the exact provision path and linkage in
   `store.computeRecipeHash`, the stored artifact manifest, and locked replay
   verification.

The artifact may retain nested logical destinations for inspection, but root
environment projection stays loader-oriented: it flattens shared libraries by
their loader-visible basename and rejects collisions across the selected
closure. This preserves LuaRocks' source-basename behavior while making an
otherwise ambiguous dynamic-loader collision explicit.

This is deliberately a domain and serialization change before a LuaRocks
parser change. It gives ordinary registry artifacts and LuaRocks-derived
artifacts the same honest native-library contract.

## Windows Certification Boundary

Moonstone uses three deliberately distinct checks for Windows behavior:

1. `zig build -Dtarget=x86_64-windows-gnu` runs on the non-Windows CI host and
   compile-checks Windows-specific Zig branches against the GNU target.
2. `.github/workflows/ci.yml` runs `tests/windows/core.ps1` on
   `windows-latest`. That runner builds Moonstone with its native Windows MSVC
   toolchain, compiles a real DLL and `LoadLibraryA` probe, and verifies actual
   `PATH`-based loader projection. Its isolated project, registry, and PowerShell
   transcript are uploaded as `windows-core-harness-state` even on failure.
3. Wine may be used only as an optional PE-process smoke test. It does not
   certify Windows filesystem, executable-discovery, PowerShell/cmd, DLL-loader,
   or MSVC-runtime behavior and must not be presented as Windows compatibility.

An Apple Silicon or Linux host cannot make the MSVC cross-link result
authoritative merely by passing `-Dtarget=x86_64-windows-msvc`: Zig needs the
Microsoft runtime libraries for that target. The native GitHub Windows runner
is therefore the authority for that target identity; no local Wine or
cross-compile result replaces it.
