# Moonstone

Moonstone is a cross-platform Lua runtime manager and package manager written in
[Zig](https://ziglang.org). It resolves dependencies into deterministic,
runtime-aware project environments backed by a content-addressed store.

## Quick start

Create a project, add packages, and synchronize its environment:

```bash
moon init . --name my-app --kind script --interpreter lua@5.4
moon add inspect
moon add rocks:lua-cjson   # LuaRocks resolver
moon sync
```

Run a script or invoke a command in the project environment:

```bash
moon run dev
moon exec lua src/main.lua
```

Use `-C` or `--directory` to select a project from another directory:

```bash
moon -C ./my-app sync
moon --directory ./my-app run dev
```

## Operational model

- `moonstone.toml` is the project manifest. It declares metadata, the selected
  Lua interpreter, dependencies, and optional `[scripts]` entries.
- `moonstone.lock` records the exact resolution, including package artifacts,
  hashes, target profiles, runtime ABI, and materialization details.
- The global content-addressed store keeps immutable artifacts under the
  Moonstone data directory. Projects share these artifacts rather than copying
  them into each project.
- `moon sync` creates or updates `.moonstone/env/`, a project-local projection
  of the locked interpreter, libraries, modules, and binaries.

The store is shared; the environment is project-specific. Use Moonstone
commands to change either one rather than editing `.moonstone/env/`, the store,
or the lockfile by hand.

## `run` and `exec`

`moon exec <command> [args...]` is the primitive projected process runner. It
sets the project environment, including executable and Lua module paths, before
starting the command.

`moon run <name>` selects a named entry in `[scripts]`, projects the same
environment, and lets the host shell interpret the script command. Keep script
entries simple; put substantial orchestration in Lua or ordinary script files.

## Runtime and ABI

Moonstone treats PUC Lua and LuaJIT runtimes as first-class packages. Native Lua
modules are checked against the selected runtime ABI and target. Switching, for
example, from Lua 5.4 to LuaJIT changes the ABI profile, so incompatible native
artifacts are not reused until `moon sync` resolves or rebuilds them.

On Windows, environment projections prefer symbolic links and fall back to
copying when links are unavailable. Developer Mode or symbolic-link privilege
avoids the copy overhead.

## Where to go next

- [Documentation map](docs/README.md) for architecture, usage, platforms, and
  protocol references
- [Usage guide](docs/USAGE.md) for package and registry workflows
- [Contributing](CONTRIBUTING.md) for project status and maintainer guidance
- [Moonstone 0.4 Upgrade Guide](https://moonstone.sh/docs/guide/v0-4/) for
  migration details

## Status and license

Moonstone is pre-1.0 alpha. APIs, registry contracts, lockfile details, and CLI
behavior may evolve.

Licensed under Apache License 2.0.
