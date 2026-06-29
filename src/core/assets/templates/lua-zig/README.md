# {{name}}

A Moonstone Lua app with a Zig-powered Lua Zig module.

## Commands

```bash
moon sync
moon run dev
```

The template demonstrates:

- Lua calling Zig: `zig.hello_from_zig(...)`
- Zig calling Lua: `zig.call_lua(function (...) ... end)`
- Shared Lua/Zig state: `zig.new_state`, `zig.increment`, `zig.count`

The Zig code exports `luaopen_{{module_name}}_zig`, and Lua loads it with:

```lua
local zig = require("{{module_name}}_zig")
```
