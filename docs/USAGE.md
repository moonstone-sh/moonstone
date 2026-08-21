# Adding a Package to Moonstone

Library packages (`kind = "lib"`) are the most common additions to the registry.

## 1. Pure Lua Libraries

If a library contains only `.lua` files, it is platform-independent.

### Constraints
- **Target**: Use `target = "native"` or `target = "any"`.
- **ABI**: Specify the minimum compatible `lua_abi` (e.g., `lua51`, `lua54`, or `luajit`).

### Descriptor Example
```toml
[package]
name = "inspect"
version = "3.1.3"
kind = "lib"

[[artifact]]
target = "native"
lua_abi = "lua54"
url = "https://..."
hash = "b3:..."
format = "tar.zst"

[artifact.provides]
lua_module = [
  { name = "inspect", path = "inspect.lua" }
]
```

## 2. Native C Modules

Native modules require specific target triples or a source fallback.

### Strategy 1: Prebuilts
Provide artifacts for common triples:
- `x86_64-linux-gnu`
- `aarch64-macos`
- `x86_64-windows-msvc`

### Strategy 2: Source Fallback (Recommended)
Always provide a `target = "source"` artifact to ensure the package works everywhere.

```toml
[[artifact]]
target = "source"
lua_abi = "lua54"
# ... hash and url ...

[artifact.materialize]
kind = "native-cmodule"
strategy = "zig-cc"
input.sources = ["src/mylib.c"]
output.module = "mylib"
output.path = "mylib.so"
```

## 3. Verification

Before publishing, test your package locally:

1. Create a local registry directory.
2. Add your `package.toml` and blob.
3. Run `moonstone index rebuild <dir>`.
4. Point your `moonstone.toml` to the local registry:
   ```toml
   [[registries]]
   url = "file:///path/to/local/registry"
   ```
5. Try adding it:
   ```bash
   # Default role is runtime
   moon add mypackage

   # Or specify a role explicitly
   moon add mypackage --role runtime
   moon add mypackage --dev
   moon add mypackage --tool
   moon add mypackage --helper
   moon add mypackage --external
   moon add mypackage --optional
   ```

See [Dependency Roles](DEPENDENCY-ROLES.md) for the full role taxonomy and [Glossary](GLOSSARY.md) for term disambiguation.

## 4. For the Brave: Manual Submission

If you prefer to bypass the interactive wizard and have already prepared a `package.toml` (or `package.json`), you can use the **Manual Mode** on the [Registry Wizard](/create/wizard/):

1. Go to the **Identity** step.
2. Click **"Brave Mode: Upload Manifest"**.
3. Select your `package.toml`.
4. The wizard will automatically parse your manifest and populate all subsequent steps (Version, Artifact, Storage).
5. Review the imported data in the final step and click **Publish**.

This is the fastest way to register multiple artifacts or complex packages with custom materialization rules.
# Adding a Runtime to Moonstone

A runtime package provides a Lua environment (e.g., PUC Lua, LuaJIT). Runtimes are unique because they are the foundation for all other packages.

## Importing Local Runtime Installations

Some runtimes are distributed as host-specific applications rather than source trees or simple archives. Moonstone should not hardcode those formats in core. Instead, use an ecosystem importer tool that normalizes the input and then registers a Moonstone runtime artifact.

For LÖVE, use `moonstone/love-importer`:

```bash
moon add --global --tool moonstone:moonstone/love-importer
moon exec --global love-importer import ~/Downloads/love-11.5-macos.zip --version 11.5
```

The importer produces `moonstone/love@11.5`, with `files/bin/love` and runtime metadata suitable for:

```toml
[[dependencies]]
name = "moonstone/love"
constraint = "11.5"
role = "runtime"
```

See [LÖVE + Moonstone](LOVE.md) for the full game workflow.

## 1. Build Process

To ensure portability, always use `zig cc` for compilation.

### Step 1: Compile for a Target
For PUC Lua 5.4.7:
```bash
make CC="zig cc -target x86_64-linux-gnu" \
     AR="zig ar rcu" \
     RANLIB="zig ranlib" \
     MYCFLAGS="-fPIC -O2 -DLUA_USE_LINUX" \
     MYLIBS=""
```

### Step 2: Organize the Layout
Moonstone expects a standard "install" structure:
```
artifact/
├── bin/
│   ├── lua
│   └── luac
├── include/
│   ├── lua.h
│   ├── luaconf.h
│   └── ...
└── lib/
    └── liblua.a
```

### Step 3: Compute the Content Hash
Generate a Blake3 hash of the directory content (deterministic sort):
```bash
# Example logic (implemented in runtime-pipeline.py)
# 1. Walk files in sorted order
# 2. Update hasher with relative path and file bytes
```

### Step 4: Package the Blob
Compress into a `tar.zst` archive:
```bash
tar -I zstd -cf lua-5.4.7-x86_64-linux.tar.zst -C artifact .
```

## 2. Descriptor Format (`package.toml`)

```toml
[package]
name = "lua"
version = "5.4.7"
kind = "runtime"
description = "PUC Lua 5.4.7"

[[artifact]]
target = "x86_64-linux-gnu"
lua_abi = "lua54"
url = "https://registry.moonstone.sh/blobs/b3/...tar.zst"
hash = "b3:..."
format = "tar.zst"

[artifact.provides]
runtime = ["lua"]
bin = ["lua", "luac"]
headers = ["lua.h", "lauxlib.h", "lualib.h"]
native_lib = ["lua"]
```

## 3. Source-Based Runtimes (Universal Support)

To support architectures not officially prebuilt, provide a `target = "source"` artifact.

### Requirements
- Must include a `materialize` section using the `command` materializer.
- Client must have `zig` installed to build from source.

Example:
```toml
[[artifact]]
target = "source"
lua_abi = "lua54"
url = "https://registry.moonstone.sh/blobs/b3/...src.tar.zst"
hash = "b3:..."
format = "tar.zst"

[artifact.materialize]
kind = "command"
command = "make"
args = ["CC=zig cc", "all"]
collect.bins = [
  { name = "lua", path = "src/lua" }
]
# ... other collections
```

When Moonstone encounters `target = "source"`, it builds the runtime locally using the host's `zig cc`.
# Dependency Roles

Moonstone classifies every dependency by **role**. The role determines how the dependency is resolved, materialized, and exposed to the project environment.

## The `moon add` API

When adding a dependency, you can declare its role explicitly:

```bash
# Canonical --role flag
moon add acme/inspect --role dev
moon add acme/comptime-gen --role tool
moon add org/sqlite-helper --role helper
moon add nvim-lua/plenary.nvim --role external

# Convenience aliases (each maps to the corresponding role)
moon add acme/inspect --dev          # same as --role dev
moon add acme/comptime-gen --tool    # same as --role tool
moon add org/sqlite-helper --helper  # same as --role helper
moon add nvim-lua/plenary.nvim --external       # same as --role external
moon add nvim-telescope/telescope.nvim --optional # same as --role optional
```

If no role is specified, the default is **runtime**.

## Available Roles

| Role      | Meaning |
|-----------|---------|
| `runtime` | Production dependency. Bundled/exported by default. |
| `dev`     | Development-only dependency (tests, fixtures). |
| `tool`    | Executable used during build/export/test workflows. |
| `helper`  | Runtime executable used internally by the package. |
| `external`    | External runtime dependency expected to be provided by the host. |
| `optional`| Optional external runtime integration. |

### Optional dependencies

The `--optional` flag sets both `role = "optional"` and `optional = true` on the dependency entry:

```bash
moon add nvim-telescope/telescope.nvim --optional
```

This produces in `moonstone.toml`:

```toml
[[dependencies]]
name = "nvim-telescope/telescope.nvim"
constraint = "*"
role = "optional"
optional = true
```

## Environment Scope Projection

Roles prevent contamination. Moonstone does not dump every dependency into one global `PATH`, `LUA_PATH`, or `LUA_CPATH`.

- **Runtime scope** — `runtime` libraries and modules
- **Dev scope** — `dev` libraries available to test/build commands
- **Tool scope** — `tool` executables (e.g., Ballad, formatters)
- **Helper scope** — `helper` executables available to the runtime package
- **External/Optional slots** — metadata only; not linked into the output closure

## Semantic Manifest Edits

The canonical storage form is explicit `[[dependencies]]` records. Tools that
need to inspect or alter a project should use Moonstone's semantic JSON API
instead of reconstructing TOML sections:

```bash
moon manifest export --json
moon manifest apply --json --force < request.json
```

The request carries the manifest `storage_revision` and bounded domain
operations. It cannot address arbitrary TOML paths, which keeps project edits
transactional and independent of storage formatting.
# Global Tools

Global tools are Moonstone packages installed into a shared tools project instead of the current project. They are useful for ecosystem commands such as `moonstone/love-importer` that you want to run from anywhere.

## Install a Tool Globally

```bash
moon add --global --tool moonstone:moonstone/love-importer
```

`--global` switches into Moonstone's global tools environment and `--tool` records the dependency with tool role semantics. Tool binaries get isolated runtime metadata just like project-local tools.

## Run a Global Tool

```bash
moon exec --global love-importer --help
moon exec --global love-importer import ~/Downloads/love-11.5-macos.zip --version 11.5
```

`moon exec --global` runs inside the global tools environment and still applies per-tool runtime scopes from `.moonstone/env/bin-runtime/<bin>/env.toml`.

## Command Execution & Argument Boundaries (`moon exec`)

`moon exec` spawns programs inside the resolved project (or global) environment:

```bash
moon exec [options] <command> [args...]
```

### Argument Boundary Rules

- **First Positional Boundary**: All Moonstone options (`--global`, `--json`, `--dev`, `--prod`, etc.) must precede `<command>`. Once `<command>` is encountered, Moonstone transfers ownership of all remaining arguments to `<command>` without interpreting them.
- **Double-Dash (`--`) Position**:
  - An optional `--` **before** `<command>` explicitly terminates Moonstone option parsing (useful if `<command>` starts with a hyphen, e.g. `moon exec -- -strange-program arg`).
  - One `--` **after** `<command>` is an optional argument delimiter and is not forwarded (e.g. `moon exec tool -- --child-flag`). Use `moon exec tool -- --` to pass one literal `--` to `tool`.
- **Direct Execution**: Arguments are passed directly via `spawn` array boundaries (`child.argv`) without shell string re-assembly, preserving exact argument boundaries.

See [LÖVE + Moonstone](LOVE.md) for a complete `love-importer` workflow.

## User Configuration Overrides

Use a dedicated configuration file for an isolated invocation, CI job, or
private registry profile:

```bash
moon --config-file ./ci/moonstone.toml sync
moon --config-file ./ci/moonstone.toml registry internal: index rebuild
```

`--config-file` is applied before command dispatch and is inherited by spawned
Moonstone processes. Its `[paths]`, `[network]`, and `[registries]` settings
therefore affect the complete command invocation. `[paths].home_directory`
derives isolated data and cache directories without changing the shell's
`MOONSTONE_HOME`.

Use typed configuration commands for supported settings; these preserve all
unrelated TOML content, including registry declarations:

```bash
moon config get network.timeout
moon config get network.timeout --default
moon config set network.timeout 15
moon config unset network.timeout
```

`moon config show` remains the broad diagnostics view. `get`, `set`, and
`unset` complete supported setting names and validate their value type.

Registry targets combine user `config.toml` and project `moonstone.toml`
registries, with project entries taking precedence when names collide. Use a
trailing colon for administrative operations:

```bash
moon registry init --file ./packages --name internal
moon registry internal: index rebuild
moon registry internal: publish --descriptor package.toml --artifact app.tar.gz
moon registry internal: doctor
```

## Where Global Tools Live

By default, the global tools project lives at:

```text
~/.local/share/moonstone/projects/global-tools
```

The path follows Moonstone data directory rules:

- `MOONSTONE_DATA` wins when set.
- `MOONSTONE_HOME` maps data to `$MOONSTONE_HOME/data`.
- `XDG_DATA_HOME` maps data to `$XDG_DATA_HOME/moonstone`.
- Otherwise Moonstone uses `~/.local/share/moonstone`.

Inside that project, Moonstone creates a normal project environment:

```text
global-tools/
  moonstone.toml
  moonstone.lock
  .moonstone/env/
    bin/
    bin-runtime/
```

Do not edit `.moonstone/env` or the global store manually. Use Moonstone commands.

## Remove a Global Tool

Global tools are stored as tool-role dependencies, so remove them with `--global --tool`:

```bash
moon remove --global --tool moonstone/love-importer
```

Use `--link` for global link registry entries:

```bash
moon remove --global --link my-linked-package
```

`--bin` remains a deprecated alias for project tool dependencies, but new commands should use `--tool`.

## Relationship to Project Tools

Project-local tool:

```bash
moon add --tool moonstone/ballad
moon exec ballad --help
```

Global tool:

```bash
moon add --global --tool moonstone:moonstone/love-importer
moon exec --global love-importer --help
```

Use project-local tools when a project needs a pinned version in its lockfile. Use global tools for developer utilities that should be available from any directory.
# LÖVE + Moonstone

Moonstone treats LÖVE as a runtime package. A LÖVE game stays in the normal development shape (`main.lua`, `conf.lua`, `src/`, `assets/`), while Moonstone puts the imported `love` binary on `PATH` and Ballad handles release exports.

## 1. Install the Importer as a Global Tool

`love-importer` is the translation boundary between host-specific LÖVE downloads and Moonstone's normalized runtime artifacts.

```bash
moon add --global --tool moonstone:moonstone/love-importer
moon exec --global love-importer --help
```

Global tools are described in [Global Tools](GLOBAL_TOOLS.md).

## 2. Import a Local LÖVE Runtime

Download the official macOS zip or provide a normalized root with `bin/love`.

```bash
moon exec --global love-importer inspect ~/Downloads/love-11.5-macos.zip
moon exec --global love-importer import ~/Downloads/love-11.5-macos.zip --version 11.5
```

On macOS, downloaded apps may carry Gatekeeper quarantine attributes. The importer does not silently bypass them. If you have verified the download and want the staged copy to avoid repeated prompts, opt in:

```bash
moon exec --global love-importer import ~/Downloads/love-11.5-macos.zip \
  --version 11.5 \
  --clear-quarantine
```

Expected result:

```text
Imported LÖVE runtime

name:       moonstone/love
version:    11.5
target:     darwin-aarch64
lua_api:    love-11
lua_abi:    lua-5.1
artifact:   b3:<hash>
path:       <moonstone-store-path>

provides:
  runtime love@11.5
  bin love -> bin/love
```

The store artifact is self-contained and exposes `files/bin/love`. macOS app imports stage the app under `files/libexec/love.app` and make `files/bin/love` point inside the artifact.

## 3. Create a LÖVE Project

```bash
moon init my-game --name my-game --template love
cd my-game
```

The template creates:

```text
my-game/
  moonstone.toml
  main.lua
  conf.lua
  partiture.lua
```

The generated manifest includes the imported runtime and a dev script:

```toml
manifest_version = 2

[[dependencies]]
name = "moonstone/love"
constraint = "11.5"
role = "runtime"

[scripts]
dev = "love ."
export = "ballad play partiture.lua"
```

Sync and run the normal LÖVE dev loop:

```bash
moon sync
moon run dev
```

`moon run dev` executes `love .` from the project root. You do not need to run from `dist/love-root` during development.

## 4. Add LuaRocks Dependencies

LÖVE 11.x uses a Lua 5.1-compatible API/ABI, so Moonstone resolves compatible Lua modules for the selected LÖVE runtime.

Example with a pure-Lua dependency:

```bash
moon add rocks:inspect
moon sync
```

Use it from `main.lua`:

```lua
local inspect = require("inspect")

local player = { x = 80, y = 120, hp = 3 }

function love.draw()
  love.graphics.print("Player: " .. inspect(player), 20, 20)
end
```

For C modules, Moonstone must have/build modules compatible with the LÖVE Lua 5.1 ABI.

## 5. Export with Ballad

Add Ballad as a project tool so the `export` script can resolve `ballad` from the project environment:

```bash
moon add --tool moonstone/ballad
moon sync
moon run export
```

The generated `partiture.lua` uses Ballad's LÖVE plugin:

```lua
local app = love.layout(project, {
  main = "main.lua",
  conf = "conf.lua",
  include = {
    "main.lua",
    "conf.lua",
    "src/**",
    "assets/**",
  },
})

emit.directory(app, { out = "dist/love-root" })
love.pack(app, { out = "dist/" .. project.name .. ".love" })
```

Development remains `moon run dev`; release packaging is Ballad's job.

## Layering Rule

- `love-importer` knows LÖVE installation formats.
- Moonstone core knows runtime artifacts and project environments.
- Ballad knows export/release layouts.
- LÖVE projects stay normal: `love .` from the project root.
