# Adding a Runtime to Moonstone

A runtime package provides a Lua environment (e.g., PUC Lua, LuaJIT). Runtimes are unique because they are the foundation for all other packages.

## 1. Build Process

To ensure portability, always use `zig cc` for compilation.

### Step 1: Compile for a Target
For PUC Lua 5.4.7:
```bash
make CC="zig cc -target x86_64-linux-gnu" \
     AR="zig ar rcu" \
     RANLIB="zig ranlib" \
     MYCFLAGS="-fPIC -O2 -DLUA_USE_LINUX" \
     MYLIBS=""
```

### Step 2: Organize the Layout
Moonstone expects a standard "install" structure:
```
artifact/
├── bin/
│   ├── lua
│   └── luac
├── include/
│   ├── lua.h
│   ├── luaconf.h
│   └── ...
└── lib/
    └── liblua.a
```

### Step 3: Compute the Content Hash
Generate a Blake3 hash of the directory content (deterministic sort):
```bash
# Example logic (implemented in runtime-pipeline.py)
# 1. Walk files in sorted order
# 2. Update hasher with relative path and file bytes
```

### Step 4: Package the Blob
Compress into a `tar.zst` archive:
```bash
tar -I zstd -cf lua-5.4.7-x86_64-linux.tar.zst -C artifact .
```

## 2. Descriptor Format (`package.toml`)

```toml
[package]
name = "lua"
version = "5.4.7"
kind = "runtime"
description = "PUC Lua 5.4.7"

[[artifact]]
target = "x86_64-linux-gnu"
lua_abi = "lua54"
url = "https://registry.moonstone.sh/blobs/b3/...tar.zst"
hash = "b3:..."
format = "tar.zst"

[artifact.provides]
runtime = ["lua"]
bin = ["lua", "luac"]
headers = ["lua.h", "lauxlib.h", "lualib.h"]
native_lib = ["lua"]
```

## 3. Source-Based Runtimes (Universal Support)

To support architectures not officially prebuilt, provide a `target = "source"` artifact.

### Requirements
- Must include a `materialize` section using the `command` materializer.
- Client must have `zig` installed to build from source.

Example:
```toml
[[artifact]]
target = "source"
lua_abi = "lua54"
url = "https://registry.moonstone.sh/blobs/b3/...src.tar.zst"
hash = "b3:..."
format = "tar.zst"

[artifact.materialize]
kind = "command"
command = "make"
args = ["CC=zig cc", "all"]
collect.bins = [
  { name = "lua", path = "src/lua" }
]
# ... other collections
```

When Moonstone encounters `target = "source"`, it builds the runtime locally using the host's `zig cc`.
