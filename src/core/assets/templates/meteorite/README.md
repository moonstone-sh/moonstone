# {{name}}

A Meteorite service project.

## Commands

```bash
moon sync
moon run generate-graph   # materialize the Meteorite graph
moon run build            # compile dist/server
moon run dev              # graph in dev mode and smoke-test routes
```

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
