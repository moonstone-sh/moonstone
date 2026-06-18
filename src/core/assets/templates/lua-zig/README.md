# {{name}}

A Moonstone Lua app with a Zig-powered Lua native module.

## Commands

```bash
moon sync
moon run dev
```

The template demonstrates:

- Lua calling Zig: `native.hello_from_zig(...)`
- Zig calling Lua: `native.call_lua(function (...) ... end)`
- Shared Lua/Zig state: `native.new_state`, `native.increment`, `native.count`

The Zig code exports `luaopen_{{module_name}}_native`, and Lua loads it with:

```lua
local native = require("{{module_name}}_native")
```
