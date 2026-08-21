# Neovim External Runtime

This example draws a deliberate boundary:

- **Moonstone** creates the project-local tool environment and runs Ballad.
- **Ballad** exports a Neovim plugin and records its host dependencies.
- **Neovim** provides the LuaJIT runtime that loads and executes the plugin.

`plenary.nvim` is intentionally a **peer dependency**, not a Moonstone LuaRocks
dependency. Moonstone must not inject it into the project LuaJIT environment:
Neovim's runtime path and the user's plugin manager own it.

## Export

```sh
moon sync
moon run export
```

The registry package at `dist/nvim-plugin/registry-artifact/` records:

```toml
name = "plenary"
package = "nvim-lua/plenary.nvim"
role = "peer"
```

Install that plugin through your Neovim plugin manager before invoking
`:NvimHostExample`.

## Host Runtime Smoke Test

This does **not** run the plugin through `moon exec lua`. It launches Neovim,
which provides the `vim` global and its own LuaJIT runtime:

```sh
moon run smoke
```

The command verifies only the host-owned module boundary. It does not execute
the `plenary.nvim` path; that happens only when Neovim runs `:NvimHostExample`
with the peer plugin installed.

## Why This Matters

Use this shape for any integration whose runtime is supplied by another host:
Neovim, OpenResty, LÖVE, a game engine, or an embedded Lua application.

Keep Moonstone scripts as discoverable entrypoints. Keep host-specific behavior
in ordinary Lua files and let the real host own its runtime API, module path,
and lifecycle.
