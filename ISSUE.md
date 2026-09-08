# Issues found while building `hydronium-ink` (a real `path:`-dependent, native-library-backed package)

Filed from real, hands-on friction building and consuming a new package
(`hydronium-ink`, a LuaJIT FFI binding to a native C++ library) inside an
existing Moonstone `orbits` workspace (`~/Workbench/user/hydronium`), then
verifying it end-to-end from a genuinely separate scratch consumer project
via `moon sync` / `moon exec`. Both issues below were reproduced for real,
not inferred from reading source — each includes the exact repro and the
real error/behavior observed. Code citations are to this checkout as of
2026-09-08.

## 1. `native_lib` provisions have no equivalent for `path:` dependencies

**Status (2026-09-08): fixed.** A linked package declares its own libraries
with `[[provides.native_lib]]` in its `moonstone.toml`
(`src/core/domain/manifest.zig`), read and validated by
`src/core/project/linked_native_library.zig`, and merged by
`src/core/project/linker.zig` into the same loader-visible map that artifact
provisions populate. Contract amendment in
`docs/maintenance/native-library-projection-contract-2026-08-09.md`;
user-facing documentation in `docs/PROJECT_ENVIRONMENT.md`; certified by
`tests/e2e/commands/path_dependency_native_library.sh`.

**What happened:** `hydronium-ink` ships a native shared library
(`libyogacore`, cross-compiled per target triple) that its Lua code loads
via `ffi.load`. During local development every consumer in this workspace
uses a `path:` dependency (`constraint = "path:../core"` etc. — verified:
no orbits member here has ever been published; there is no `partiture.lua`
for `core`, `dom`, or `luax`). `path:` dependencies have no way to declare
"this also provides a native_lib" at all, so the native library simply
does not get projected into the consumer's environment. The Lua package
was left to hand-roll its own fallback (walk up from its own materialized
file location to a conventional `native/dist/<triple>/` directory) just to
find its own native library during local iteration.

**Root cause, as far as I traced it:** `native_lib` is a first-class
concept end-to-end for registry/artifact-based dependencies —
`manifest.FeatureProvision`/`ArtifactManifest.provides.native_lib`
(`src/core/domain/manifest.zig`), persisted by
`src/core/store/driver.zig`, collected by materializers (e.g.
`src/core/materialization/materializers/command.zig:277`), and finally
projected into `.moonstone/env/lib/native/<name>` with the
`LD_LIBRARY_PATH`/`DYLD_FALLBACK_LIBRARY_PATH`/`PATH` wiring documented in
`docs/maintenance/native-library-projection-contract-2026-08-09.md`. But
the `path:` resolution source (`src/core/resolution/sources/path.zig`)
only ever produces a `Candidate` with a `local_path` and reads
`moonstone.toml` for `name`/`version`/`kind` — it never reads or acts on
that manifest's `[collect].native_lib`/`[[artifacts.provides]]`-shaped
declarations, and `src/core/project/linker.zig`'s path-dependency
projection (`projectFileWithFallback`, see issue 2 below) only ever
projects `src/` files into `LUA_PATH`, never anything into
`.moonstone/env/lib/native/`.

**Why it matters:** Moonstone already has a real "fast local iteration
without a real publish" story for registry packages
(`docs/USAGE.md`/`docs/REGISTRY_MODEL.md`'s local file-registry workflow),
but the *even more local* `path:` case — which every in-progress,
not-yet-published package in a workspace actually uses day to day — has
no equivalent for anything beyond plain Lua modules. Any package with a
native component (FFI binding, C extension) hits this on day one of local
development.

**Suggested direction:** let `src/core/resolution/sources/path.zig` read
the target's `native_lib`/collect-style declarations (or a new, simpler
declaration shaped for this case) from its `moonstone.toml`, and have
`linker.zig`'s path-dependency projection also symlink/copy those into
`.moonstone/env/lib/native/<name>`, reusing the loader-env-var wiring
`run_env.zig` already has for the registry-artifact case. Doesn't need
target-matrix resolution the way a published artifact does — a `path:`
dependency is already pinned to one concrete filesystem location, so
there's no "pick the right target" step, only "project what's already
there."

## 2. `path:` dependency projection is per-file symlinks, which silently defeats `debug.getinfo`-based self-location — and this isn't documented anywhere I found

**Status (2026-09-08): fixed, both ways.** The symlink projection and its
`debug.getinfo` consequence are now documented in `docs/PROJECT_ENVIRONMENT.md`
(linked from `docs/README.md`, `docs/ARCHITECTURE.md`, and `docs/USAGE.md`), and
`moon sync` now records every projected package's real, symlink-resolved root in
`.moonstone/env/env.toml`, which `src/core/project/run_env.zig` exports as
`MOONSTONE_PACKAGE_ROOT_<NAME>` alongside `LUA_PATH`/`LUA_CPATH`. Certified by
`tests/e2e/commands/package_root_projection.sh`.

**What happened:** After fixing (1) with a hand-rolled fallback that
locates the package's own native library relative to its own Lua file's
location (`debug.getinfo(1, "S").source`, the same "resolve my own
directory, no hardcoded paths" technique this ecosystem's own consumers
already use — see `~/Workbench/user/config/nvim/lua/plugins/luax.lua` for
another real example of the same pattern), the fallback worked inside the
`hydronium` workspace itself but **failed** the moment it was consumed
from a genuinely separate scratch project via `moon sync`:

```
$ cat .moonstone/env/share/lua/5.1/hydronium_ink/yoga_ffi.lua
# (not a real file — a symlink)
$ ls -la .moonstone/env/share/lua/5.1/hydronium_ink/
lrwxr-xr-x  init.lua -> /Users/.../hydronium/ink/src/hydronium_ink/init.lua
lrwxr-xr-x  yoga_ffi.lua -> /Users/.../hydronium/ink/src/hydronium_ink/yoga_ffi.lua
drwxr-xr-x  host/          # a real directory, not a symlink; its own contents are symlinked individually
```

`debug.getinfo`'s `source` field reports the path `require`/`LUA_PATH`
actually opened — i.e. the **symlink's own path**, inside the consumer's
`.moonstone/env/`, not the symlink's target. Any relative-path
computation from that (e.g. "my native library lives two directories up
from me") lands inside the consumer's own `.moonstone/env/` tree instead
of the real package directory. Fixed on the package's side by resolving
through the symlink with `realpath(3)` before computing anything relative
— but every package that needs to locate its own real installation root
(for a sibling non-Lua asset: native libs, data files, templates) will
have to reinvent this same fix independently, with no guidance from
Moonstone that the symlink behavior exists at all.

**Root cause, confirmed in source:**
`src/core/project/linker.zig:688-706`, `projectFileWithFallback`:
projects each file with `destination_dir.symLink(io, source_path,
destination_name, .{})`, one file at a time (matching what was observed:
files are symlinked individually, not the whole `src/` tree as one
symlink) — falling back to a real copy **only** on Windows when the
symlink call itself fails (`isWindowsProjectionSymlinkFallback`,
`removeFailedFileSymlinkEntry`). On macOS/Linux, `path:` dependency
projection is unconditionally per-file symlinks.

**Why it matters:** this is a correct, deliberate design choice (a
project environment is derived state, cheap to keep as live links to the
real source — the comment at line 699 says as much), not a bug in
itself. The gap is that it's an **invisible footgun for package authors**:
nothing in `docs/ARCHITECTURE.md`, `docs/USAGE.md`, or
`docs/REGISTRY_MODEL.md` (the docs I checked) mentions that `path:`
consumers see symlinks, or that this means `debug.getinfo`-based
self-location needs an extra resolution step to work correctly once a
package leaves its own repo. I found this out by writing a broken
fallback, testing it only inside the monorepo (where nothing is
symlinked, so it worked), and then hitting a real failure only once I
built a genuinely separate scratch consumer.

**Suggested direction, either would resolve it:**
- Document the symlink behavior explicitly (a short note in
  `docs/ARCHITECTURE.md` or a new `docs/PROJECT_ENVIRONMENT.md`), including
  the `debug.getinfo` implication and the `realpath(3)` fix, so the next
  package author doesn't have to rediscover it by shipping a broken
  fallback first; **or**
- Give packages a built-in way to find their own real root regardless of
  projection method — e.g. an injected `MOONSTONE_PACKAGE_ROOT`-style
  environment variable per linked package, or a small runtime helper
  module — so authors don't need `ffi`/`realpath` (LuaJIT-only) or a
  subprocess (`readlink`) just to reliably answer "where am I really
  installed."

## Minor, related: default manifest scaffolding can silently drift from the interpreter actually used

**Status (2026-09-08): not implemented, deliberately.** Two corrections to the
diagnosis below, then the reason. First, `runtimeAbiMatches`
(`src/core/resolution/options.zig:91`) is not a raw string comparison: it calls
`normalizeRuntimeAbi`, which maps `luajit`/`love` to `5.1` and strips `lua`,
`lua-`, and operator prefixes, so `lua54`, `lua-5.4`, `5.4` and `^5.4` all
compare equal. What it compares is the ABI *number*, so `lua`+`5.4` versus real
LuaJIT (`5.1`) is a true ABI difference that the check correctly refused.
Second, the check that would actually have caught this — "the declared
interpreter has never been used to run anything" — needs persisted per-project
execution provenance, which no part of Moonstone records today and which cuts
against the project's derived-state model. A cheaper substitute (compare
`moonstone.toml`'s `[interpreter]` against the runtime in
`.moonstone/env/env.toml`) is implementable and catches manifest-edited-without-
resync drift, but it would *not* have caught this case: the environment was
built from the same manifest that was wrong, and LuaJIT was being run outside
`moon exec` entirely. Rather than ship a check that looks like it covers the
reported case and does not, this is left open.

Not something I hit as a hard failure, but worth noting since issue 1's
root cause involved it: `hydronium/core/moonstone.toml` declared
`[interpreter] name = "lua" version = "5.4" abi = "5.4"` while every real
invocation of its code in this workspace's own test suite has always run
under real LuaJIT (which implements the 5.1 ABI, not 5.4 — confirmed via
`moon interpreter list`: `moonstone/luajit 2.1.0 lua51`). This silently
built up until a real `moon sync` against a path-dependent consumer
finally surfaced it as the `LinkedRuntimeAbiMismatch` error
(`src/cli/commands/sync.zig:2811`, backed by the strict string comparison
in `src/core/resolution/options.zig:91`'s `runtimeAbiMatches` — it has no
concept that `lua`+`5.4` and `luajit`+`5.1` are different families, only
that the ABI label strings didn't match). A `moon doctor` check that
flags "this project's `moonstone.toml` interpreter has never actually
been used to run anything through `moon exec`" (or, more simply, warns
when `moon exec` is invoked under an interpreter that doesn't match the
manifest at all) would have caught this months earlier than a consumer's
`moon sync` failure did.
