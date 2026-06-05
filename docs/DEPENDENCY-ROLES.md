# Dependency Roles

Moonstone classifies every dependency by **role**. The role determines how the dependency is resolved, materialized, and exposed to the project environment.

## The `moon add` API

When adding a dependency, you can declare its role explicitly:

```bash
# Canonical --role flag
moon add acme/inspect --role dev
moon add acme/comptime-gen --role tool
moon add org/sqlite-helper --role helper
moon add nvim-lua/plenary.nvim --role peer

# Convenience aliases (each maps to the corresponding role)
moon add acme/inspect --dev          # same as --role dev
moon add acme/comptime-gen --tool    # same as --role tool
moon add org/sqlite-helper --helper  # same as --role helper
moon add nvim-lua/plenary.nvim --peer       # same as --role peer
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
| `peer`    | External runtime dependency expected to be provided by the host. |
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
- **Peer/Optional slots** — metadata only; not linked into the output closure

## Authoring Aliases

In `moonstone.toml` you may use legacy section names that canonicalize to `role`:

```toml
[dependencies.dev]
# equivalent to [[dependencies]] role = "dev"

[dependencies.vendor-exec]
# equivalent to [[dependencies]] role = "helper"

[dependencies.runtime-exec]
# equivalent to [[dependencies]] role = "helper"
```

These aliases are preserved for backward compatibility but resolve to the canonical flat-array format internally.
