# {{name}}

A Meteorite service project.

## Commands

```bash
moon sync
moon run generate-graph   # materialize the Meteorite graph
moon run build            # compile dist/server
moon run dev              # start the HMR dev loop (rebuilds + Lua reloads)
```

The `dev` script starts the Meteorite dev loop: it watches `src/`, `native/`,
`build.zig`, and `moonstone.toml`, regenerates the graph, rebuilds the server
when native/router/graph shape changes, and reloads inline Lua handlers and
plugins in-process when only Lua/plugin chunks changed.

The loop uses `scripts/guard.sh` to clean stale dev supervisors and `dist/server`
listeners before handoff. If port `8080` looks stuck after an interrupted session,
run `sh scripts/guard.sh status` or `sh scripts/guard.sh handoff` from the repo
root.

## Release Exports

Production exports are owned by the Meteorite Ballad plugin:

```lua
local ballad = require("ballad")

return ballad.partiture(function(p)
  local meteorite = p:use("meteorite.ballad")
  local release = meteorite.release({ mode = "hybrid", output = "dist/server" })
  p.sink.directory(release, { out = "dist/release", file_graph = true })
end)
```

Use `mode = "static"` for Zig-only releases. Static mode fails with source
locations if inline Lua handlers, Lua file/module handlers, or scoped Lua plugins
remain in the graph. Use `mode = "hybrid"` when shipping Lua handlers/plugins;
the export includes lifted inline chunks and Moonstone Lua module/C-module trees.

## Build flags

The `build` script forwards all extra arguments to `zig build install-server`,
so cross-compilation and optimization flags work as usual:

```bash
moon run build -- -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSmall
```

Meteorite-specific build knobs are available too:

```bash
# Default correctness backend
moon run build -- -Dbackend=std_http

# Experimental high-performance backend
moon run build -- \
  -Dbackend=fast_http \
  -Dfast-http-strategy=pool \
  -Dhybrid-profile=optimized
```
