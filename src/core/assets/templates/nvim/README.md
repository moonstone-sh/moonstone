# {{name}}

A Neovim plugin project scaffolded by Moonstone.

## Commands

```bash
moon sync
moon run export  # export dist/nvim-plugin with Ballad
moon run smoke   # run a headless Neovim setup smoke test
```

`partiture.lua` defaults the Neovim package target to `{{nvim_version}}` and also honors `NVIM_VERSION`:

```bash
NVIM_VERSION=0.13.0 moon run export
```

## Development

The project uses LuaJIT/Lua 5.1 semantics to match Neovim. The package itself remains a normal Moonstone Lua library, while Ballad exports a Neovim plugin layout and registry artifact.

Plugin entrypoints:

- `lua/{{module_name}}/init.lua` exposes `setup(opts)`.
- `lua/{{module_name}}/config.lua` stores defaults.
- `plugin/{{module_name}}.lua` auto-loads the plugin in Neovim.
- `doc/{{module_name}}.txt` is the plugin help file.

## External plugin dependencies

Declare Neovim plugin dependencies explicitly in `partiture.lua` with `ballad.plugins.nvim.extern`:

```lua
dependencies = ballad.plugins.nvim.extern({
  "plenary",
  telescope = { package = "nvim-telescope/telescope.nvim", optional = true },
})
```

Ballad scans `require(...)` calls during export and suggests known plugin dependencies for unresolved modules.
