# The project environment

`moon sync` builds `.moonstone/env` from the resolved dependency graph. This
document describes what that directory physically contains, because two of its
properties are observable from inside a running Lua program and have surprised
package authors: dependencies are projected as **symlinks**, and a package
therefore cannot locate its own installation directory from
`debug.getinfo(1, "S").source`.

The environment is derived state. It is rebuilt from `moonstone.lock` and the
store, and deleting it is always safe.

## Layout

```text
.moonstone/env/
  env.toml                 runtime identity, target flavor, projected package roots
  dependencies.toml        the projected closure, for tooling
  bin/                     public binaries
  libexec/<namespace>/<name>/  whole-package mounts, for stable references
  libexec/<name>/          namespace-less packages, and compatibility aliases
  share/lua/<version>/     Lua modules            → LUA_PATH
  share/lua/<version>/moonstone/  generated: target, project, variants
  lib/lua/<version>/       Lua C modules          → LUA_CPATH
  lib/native/              loadable native libraries → host loader path
```

`moon exec`, `moon run`, and `moon env` all project the same variables:
`PATH`, `LUA_PATH`, `LUA_CPATH`, the host's native-library search variable
(`LD_LIBRARY_PATH`, `DYLD_FALLBACK_LIBRARY_PATH`, or `PATH` on Windows), and one
`MOONSTONE_PACKAGE_ROOT_*` variable per projected package, and
`MOONSTONE_TARGET` (the environment's flavor id; see below).

## Projection is by symlink, one file at a time

Everything under `share/lua/`, `lib/lua/`, `lib/native/`, and `bin/` is a
symbolic link to the real file — in the immutable store for a registry
dependency, or in the developer's working tree for a `path:`/`link:`
dependency. Under the module and library trees, directories are recreated and
their contents linked individually rather than one directory being linked
whole, so a consumer sees:

```console
$ ls -la .moonstone/env/share/lua/5.1/hydronium_ink/
drwxr-xr-x  host/
lrwxr-xr-x  init.lua     -> /workspace/hydronium/ink/src/hydronium_ink/init.lua
lrwxr-xr-x  yoga_ffi.lua -> /workspace/hydronium/ink/src/hydronium_ink/yoga_ffi.lua
```

`libexec/<namespace>/<name>` is instead a single directory link to the whole
package.

### `libexec/` names cannot collide

Each package is mounted at a path derived from its full name:
`moonstone/meteorite` at `libexec/moonstone/meteorite`, `hydronium/ballad` at
`libexec/hydronium/ballad`. Packages without a namespace (LuaRocks) keep
`libexec/<name>`. Reference these paths from build scripts and configs.

For compatibility, a namespaced package is also linked at its old flat path
`libexec/<local name>` (or the name its build published its runtime under,
such as `hydronium-create`), but only when exactly one package in the
environment claims that name and it is not a namespace directory. Before
0.5.9 every package was mounted flat, and a later package silently replaced
an earlier one with the same local name (`hydronium/meteorite` vs
`moonstone/meteorite`). Which package a path reached depended on projection
order. A contested flat name is now absent rather than wrong, and `env.toml`
lists it:

```toml
[[libexec_alias_conflict]]
alias = "meteorite"
packages = ["hydronium/meteorite", "moonstone/meteorite"]
```

This is deliberate: an environment that links rather than copies is cheap to
rebuild, shares bytes between projects, and makes an edit in a linked working
tree visible immediately.

The single exception is Windows, where creating a symlink can require a
privilege the user does not hold. When `Dir.symLink` fails there, Moonstone
copies that one projection instead (`isWindowsProjectionSymlinkFallback` in
`src/core/project/linker.zig`). On macOS, Linux, and FreeBSD the projection is
unconditionally symlinks.

### Consequence: `debug.getinfo` reports the link, not the target

Lua's `debug.getinfo(1, "S").source` reports the path that `require` opened,
which is the symlink's own path inside the *consumer's* `.moonstone/env`. It is
not the real file's path.

A package that computes a sibling asset's location relative to its own module
file therefore lands inside the consumer's environment tree:

```lua
-- Works inside the package's own repository. Breaks in every consumer.
local here = debug.getinfo(1, "S").source:sub(2)
local root = here:match("^(.*)/src/mypkg/init%.lua$")
local library = root .. "/native/dist/libmypkg.so"  -- no such file
```

The failure is invisible during development inside the package's own
repository, where nothing is symlinked, and appears only once the package is
consumed from another project.

## Finding your own package root

Moonstone answers this directly rather than leaving each package to resolve
symlinks itself (which would otherwise require `ffi`, a `readlink` subprocess,
or a hardcoded path).

For every non-metadata package projected into the environment, `moon sync`
records the package's **real, symlink-resolved** root in `env.toml`:

```toml
[[package]]
name = "hydronium-ink"
root = "/workspace/hydronium/ink"
projection = "live"
env = "MOONSTONE_PACKAGE_ROOT_HYDRONIUM_INK"
```

and `moon exec`/`moon run`/`moon env --shell` export it:

```lua
local root = assert(os.getenv("MOONSTONE_PACKAGE_ROOT_HYDRONIUM_INK"),
  "hydronium-ink must be run inside its Moonstone project environment")
local library = root .. "/native/dist/libyogacore.so"
```

### Variable naming

The variable name is `MOONSTONE_PACKAGE_ROOT_` followed by the package's
declared coordinate, ASCII-upper-cased, with every character outside `A-Z` and
`0-9` replaced by `_`:

| Package coordinate | Variable |
| --- | --- |
| `hydronium-ink` | `MOONSTONE_PACKAGE_ROOT_HYDRONIUM_INK` |
| `moonstone/ballad` | `MOONSTONE_PACKAGE_ROOT_MOONSTONE_BALLAD` |
| `lua.cjson` | `MOONSTONE_PACKAGE_ROOT_LUA_CJSON` |

That mapping is deterministic but not injective: `a-b/c` and `a/b-c` produce
the same variable. Moonstone refuses to guess which package owns the name and
fails the sync with `PackageRootConflict` instead.

If one coordinate is projected from two different directories, the root is
genuinely unanswerable. Moonstone records nothing for it and exports no
variable, rather than exporting a path that is right half the time. A package
that reads the variable should treat a missing value as "not resolvable here",
not as a guarantee that it will always be present.

### What `root` points at

| `projection` | `root` |
| --- | --- |
| `live` | the `path:`/`link:` dependency's own directory — the tree you edit |
| `store` | the artifact's payload directory in the immutable store |

Both are real directories, not links, so a package does not need to know how it
was installed. A store root is immutable; do not write to it.

`moon env` and `moon env --json` list every recorded root, so the mapping is
inspectable without reading `env.toml`.

### Scope

The variables describe *this* project environment only. They are absent when a
program runs outside `moon exec`/`moon run`, and a package that can also run
outside a Moonstone environment should keep its existing fallback and treat the
variable as the preferred answer rather than the only one.

## Native libraries in a linked working tree

A published artifact declares `native_lib` provisions in its registry
descriptor. A `path:`/`link:` dependency is never published, so it declares them
in its own `moonstone.toml`:

```toml
[[provides.native_lib]]
name = "yogacore"
path = "native/dist/aarch64-macos/libyogacore.dylib"

[[provides.native_lib]]
name = "yogacore-archive"
path = "native/dist/aarch64-macos/libyogacore.a"
linkage = "static"
```

- `path` is relative to the package directory, uses `/`, and may not escape the
  package.
- `linkage` defaults to `shared`. A `shared` entry is linked into
  `.moonstone/env/lib/native/<basename>` and becomes visible to the host loader;
  a `static` entry is retained in the package but never projected.
- The loader-visible basename is the project-wide conflict key, exactly as for
  artifact provisions. Two selected dependencies providing the same filename is
  an error.
- A declared file that does not exist fails the sync with a diagnostic naming
  the path, rather than producing an environment that is quietly missing a
  library.
- There is no target-matrix selection: a `path:` dependency is already pinned to
  one directory on this host, and `moon sync` refuses live sources for a foreign
  target profile anyway. Selecting the right build for the host, if the package
  ships several, is the package's own responsibility.

Moonstone does not rewrite install names or rpaths and does not inspect a
binary's dependency graph. See
[`maintenance/native-library-projection-contract-2026-08-09.md`](maintenance/native-library-projection-contract-2026-08-09.md)
for the full native-library boundary and its explicit non-goals.

## Flavors: one package for several Luas

A *flavor* is what Lua source can observe about where it runs: the language
(`lua51`…`lua55`, `luajit`, `luau`) and the host os and arch. It is not the C
ABI, which only native modules see and which the store already realizes per
artifact. The flavor's id is `lua54-aarch64-macos`, `luajit-x86_64-linux`,
and so on; `env.toml` records it under `[target]`.

### Variant files

A package can ship one file per flavor for the same module by tagging the
file name with `@<tag>` before the extension:

```text
src/lexlib/lexer.lua             fallback (optional)
src/lexlib/lexer@lua54.lua
src/lexlib/lexer@luajit.lua
src/lexlib/fs@lua51@windows.lua
```

`moon sync` projects exactly one of them as `lexlib/lexer.lua`, so consumers
just `require("lexlib.lexer")`. The tags are:

| dimension | tags | matches |
|---|---|---|
| language | `lua51` `lua52` `lua53` `lua54` `lua55` | that PUC level; `lua51` also matches LuaJIT, less specifically than `luajit` |
| | `luajit` `luau` | that family only (Luau never inherits `lua51`) |
| os | `linux` `macos` `windows` `freebsd` | the host os |
| arch | `x86_64` `aarch64` `riscv64` | the host arch |

Rules:

- A file is a variant only if every tag after `@` is in the table, so an
  unrelated `name@thing.lua` is an ordinary module. `_` is never a separator:
  existing modules such as `parser_luajit.lua` keep their names.
- Tags appear in dimension order (language, os, arch), at most one each.
  `lexer@linux@lua54.lua` fails the sync.
- The winner must be at least as specific as every other matching file on
  each dimension. `fs@lua54.lua` and `fs@linux.lua` both matching is an
  error, not a coin flip: add `fs@lua54@linux.lua` or remove one.
- If nothing matches, the untagged file is used; if there is none, the module
  is absent for that flavor.

Selection happens at link time, so it costs nothing at runtime and needs no
bundler. The package's own files are never renamed: the environment holds a
`lexer.lua` link whose target is `lexer@lua54.lua`.

### The generated `moonstone` modules

Every environment contains a reserved `moonstone` module family. A
dependency that projects its own `moonstone` module fails the sync.

```lua
local target = require("moonstone.target")
-- { id = "lua54-aarch64-macos", family = "lua", level = 54,
--   os = "macos", arch = "aarch64",
--   runtime = { name = "lua", version = "5.4.7", abi = "lua54" } }

local project = require("moonstone.project")
-- { name, version, kind, description?, dependencies = { {name, version, role}, ... } }

if target.level >= 53 then ... else ... end
```

`require("moonstone")` returns `{ target, project, variants }`. Both data
modules are constant tables with LuaLS annotations, and nothing in them
depends on the machine (no paths, no timestamps), so the same project and
flavor always produce the same bytes.

A project's **own** sources are not projected, so their variants need the
runtime searcher, which probes the tagged names on `package.path`:

```lua
require("moonstone.variants").install()   -- once, in the entry point
require("util.compat")                     -- loads util/compat@lua54.lua on 5.4
```

### Contract for build tools (Quaver)

A bundler that specializes code for a flavor reads:

1. `MOONSTONE_TARGET`: the flavor to build for. `moon exec`/`moon run`
   set it from `env.toml` **unless the caller already set it**, so
   `MOONSTONE_TARGET=lua51-x86_64-linux moon run build` asks for a flavor other
   than the host's.
2. `moonstone.variants`: the selection rule, in Lua (`parse`, `match`,
   `select`, `suffixes`, `resolve`). It is the same rule as the linker's
   `src/core/platform/flavor.zig`; `tests/lua/variants_spec.lua` and the Zig
   tests share their cases. A tool picks files with it instead of
   reimplementing it.
3. `moonstone.target` and `moonstone.project` fields are compile-time
   constants. For a non-host `MOONSTONE_TARGET`, the tool builds the target
   table from the id (family, level, os, arch) and must not fold
   `target.runtime`, which describes the host interpreter.

A tool may fold a field access only when the module was bound by
`local x = require("moonstone.target")` (or `.project`) and `x` is never
reassigned. After folding, a branch whose condition is constant can be
dropped. Code that is syntactically invalid for some flavor (`<const>`,
`//`, Luau types) cannot live in a dropped branch, because the other flavors'
parsers still have to read it. Put it in a variant file.
