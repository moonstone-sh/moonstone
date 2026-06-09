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
[dependencies.runtime]
"moonstone:moonstone/love" = "11.5"

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
