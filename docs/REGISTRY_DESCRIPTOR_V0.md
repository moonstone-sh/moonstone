# Canonical Registry Descriptor v0

Registry `package.toml` files are authoritative. SQL tables are disposable search projections rebuilt from canonical descriptors.

```toml
[package]
name = "inspect"
version = "3.1.3"
kind = "lib"

[[artifacts]]
id = "lua_module-any"
kind = "lua_module"
target = "any"
hash = "b3:<64 lowercase hex characters>"
bytes = 1234
url = "blobs/b3/aa/bb/<digest>.tar.gz"
format = "tar.gz"
recipe_hash = "b3:<64 lowercase hex characters>"

[artifacts.materialize]
type = "archive"
strip_components = 0

[[artifacts.provides]]
kind = "lua_module"
name = "inspect"
path = "lua/inspect.lua"
```

Frozen artifact kinds are `runtime`, `lua_module`, `lua_cmodule`, `bin`, `tool`, and `source`. Frozen provision kinds are `runtime`, `bin`, `lua_module`, `lua_cmodule`, `lib`, `include`, `script`, and `asset`. Frozen materializers are `archive`, `command`, `cmake`, and `native_cmodule`. Frozen formats are `tar.gz`, `tar.zst`, and `zip`.

Legacy singular `[[artifact]]`, top-level `[compat]`, and top-level `[source]` registry descriptors are intentionally unsupported.
