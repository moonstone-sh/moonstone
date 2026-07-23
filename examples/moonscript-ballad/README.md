# MoonScript & Ballad Integration Example

This example demonstrates how Moonstone isolates and manages [MoonScript](https://moonscript.org) alongside [Ballad](https://moonstone.sh/docs/ballad) without global executable conflicts.

## Executable Disambiguation

Because standard shell `PATH` resolution selects whichever executable appears first, installing Moonstone and MoonScript globally could cause command name collisions:

- **Outer `moon`**: The globally installed Moonstone CLI (`moon`).
- **Inner `moon`**: The project-local MoonScript executable resolved inside `.moonstone/env/`.

```sh
# Synchronize environment dependencies (Lua, MoonScript, dkjson, busted)
moon sync

# Execute MoonScript using the project-local compiler/runner
moon exec moon src/main.moon

# Build Lua output with moonc
moon exec moonc -t build src/

# Run Ballad export pipeline
moon exec ballad play partiture.lua
```

For a complete explanation of isolated resolution and command forwarding, see the [MoonScript Coexistence Guide](https://moonstone.sh/docs/guides/moonscript).
