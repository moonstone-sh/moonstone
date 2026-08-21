# Moonstone Glossary

Disambiguation of terms introduced by the dependency-role and capability model.

---

## Kind vs. DependencyRole

**Kind** (`kind = "lib" | "bin" | "script" | "runtime"`)  
→ What the **package provides** to the ecosystem.

- `lib` — reusable Lua/C library
- `bin` — executable command
- `script` — standalone script
- `runtime` — Lua interpreter (PUC Lua, LuaJIT)

**DependencyRole** (`role = "runtime" | "dev" | "tool" | "helper" | "external" | "optional"`)  
→ How the **project consumes** the package.

- `runtime` — production dependency
- `dev` — development-only dependency
- `tool` — build/export/test executable
- `helper` — runtime executable dependency used internally by the package
- `external` — external runtime dependency provided by the host environment
- `optional` — optional external runtime integration

**Rule of thumb:** `Kind` is on the package descriptor (`package.toml`). `DependencyRole` is on the project manifest (`moonstone.toml`).

---

## helper

A **helper** is a runtime executable dependency used internally by the package.

Examples:
- sqlite sidecar
- native sorter
- image processing helper
- Python-backed shim
- shell-backed runtime executable

Rules:
- Part of the runtime/export closure by default.
- Not automatically exposed as user-facing commands.
- May have its own runtime requirements.
- Must be available to the final artifact unless export policy externalizes them.

**Authoring aliases:** `vendor-exec` → `helper`, `runtime-exec` → `helper`.

---

## tool

A **tool** is an executable package used by build/export/test workflows.

Examples:
- Ballad (deterministic exporter)
- Lua formatter
- Test runner
- Code generator

Rules:
- Available to `moon exec <tool>`.
- Not mixed into the project runtime `PATH` or `LUA_PATH` by default.
- Ignored for runtime export.

---

## external

An **external** dependency is a runtime dependency expected to be provided externally (by the host environment or a plugin manager).

Examples:
- Neovim plugin depending on `plenary.nvim`
- LÖVE module depending on the LÖVE runtime

Rules:
- Not bundled by default.
- Emitted as metadata.
- `require` / `import` remains in exported code.
- Resolver validates metadata if the package is available.

---

## optional

An **optional** dependency is an optional runtime integration.

Rules:
- Not bundled by default.
- Emitted as optional metadata.
- `require` / `import` may remain guarded by conditional checks.

---

## dev

A **dev** dependency is a development-only library or fixture.

Rules:
- Available to test/build commands.
- Not exported with the runtime bundle.

---

## runtime

A **runtime** dependency is a production library or module.

Rules:
- Bundled/exported by default unless externalized.
- Contributes to `LUA_PATH` / `LUA_CPATH`.

---

## Multi-Role Dependencies

The same package may appear multiple times with different roles:

```toml
[[dependencies]]
name = "moonstone/my-lib"
constraint = "1.0"
role = "runtime"

[[dependencies]]
name = "moonstone/my-lib"
constraint = "1.0"
role = "dev"
```

Moonstone preserves all roles. The linker places capabilities into the correct scopes.

---

## Multi-Capability Package Model

A single package may provide more than one kind of thing:

| Capability    | Purpose                              |
|---------------|--------------------------------------|
| `lua_module`  | Lua source module                    |
| `lua_cmodule` | Native C module                      |
| `bin`         | Executable binary                    |
| `script`      | Standalone script                    |
| `header`      | C header files                       |
| `lib`         | Static/dynamic native library        |
| `runtime`     | Lua interpreter                      |
| `asset`       | Static assets (images, sounds, etc.) |
| `ballad_plugin`| Ballad pipeline plugin              |

A package declares capabilities via `[[provides]]` entries in its descriptor.

---

## Orbits (Workspaces)

An **Orbit** is a workspace setup where multiple local projects/packages are
managed from a single root project. Each child remains an independent
Moonstone project with its own isolated environment and `moonstone.lock`.

**Key Concepts:**
- Defined using the `[[orbits.member]]` array in `moonstone.toml` of the root project.
- A member specifies a `name` and a `path`.
- An orbit path must be a child project directory with its own valid `moonstone.toml`.
- Orbit names and paths are unique within the root project.
- `moon orbit sync` synchronizes every configured child, or one selected child;
  `moon sync` continues to synchronize only the current project.
- `moon orbit sync --locked` requires each selected child lockfile to be
  current; `--update` refreshes it within declared constraints; `--offline`
  limits resolution to locally available sources.
- `moon orbit exec` and `moon orbit run` execute within the selected child
  environment without introducing a separate executor.

Orbit members keep independent dependency closures and runtime scopes. A path
or link dependency brought in by an orbit is expanded with its transitive
descriptor dependencies before Moonstone links the child environment. Pure Lua
dependencies may cross an isolated tool runtime boundary; native Lua modules
remain ABI-bound to their matching runtime.

Ballad can consume an orbit only when a parent partiture explicitly maps it to
a child partiture. This is not Orbit metadata: Moonstone remains unaware of
Ballad release policy, while `moon orbit exec` supplies the child-scoped
interpreter and tool closure needed to run the export safely.

**Managing Members:**
```bash
moon orbit add --name openresty --path bench/competitors/openresty
moon orbit remove openresty
moon orbit sync                 # all configured children
moon orbit sync openresty       # one child
```

`moon orbit add --path` offers completion for descendant directories that
contain `moonstone.toml`. It rejects paths outside the root project, the root
project itself, missing or invalid child manifests, duplicate names, and a
second orbit declaration for the same path.

**Example Definition:**
```toml
[[orbits.member]]
name = "meteorite"
path = "bench/meteorite"

[[orbits.member]]
name = "openresty"
path = "bench/openresty"
```
