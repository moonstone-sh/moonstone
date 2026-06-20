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
