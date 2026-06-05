# Adding a Package to Moonstone

Library packages (`kind = "lib"`) are the most common additions to the registry.

## 1. Pure Lua Libraries

If a library contains only `.lua` files, it is platform-independent.

### Constraints
- **Target**: Use `target = "native"` or `target = "any"`.
- **ABI**: Specify the minimum compatible `lua_abi` (e.g., `lua51`, `lua54`, or `luajit`).

### Descriptor Example
```toml
[package]
name = "inspect"
version = "3.1.3"
kind = "lib"

[[artifact]]
target = "native"
lua_abi = "lua54"
url = "https://..."
hash = "b3:..."
format = "tar.zst"

[artifact.provides]
lua_module = [
  { name = "inspect", path = "inspect.lua" }
]
```

## 2. Native C Modules

Native modules require specific target triples or a source fallback.

### Strategy 1: Prebuilts
Provide artifacts for common triples:
- `x86_64-linux-gnu`
- `aarch64-macos`
- `x86_64-windows-msvc`

### Strategy 2: Source Fallback (Recommended)
Always provide a `target = "source"` artifact to ensure the package works everywhere.

```toml
[[artifact]]
target = "source"
lua_abi = "lua54"
# ... hash and url ...

[artifact.materialize]
kind = "native-cmodule"
strategy = "zig-cc"
input.sources = ["src/mylib.c"]
output.module = "mylib"
output.path = "mylib.so"
```

## 3. Verification

Before publishing, test your package locally:

1. Create a local registry directory.
2. Add your `package.toml` and blob.
3. Run `moonstone index rebuild <dir>`.
4. Point your `moonstone.toml` to the local registry:
   ```toml
   [[registries]]
   url = "file:///path/to/local/registry"
   ```
5. Try adding it:
   ```bash
   # Default role is runtime
   moon add mypackage

   # Or specify a role explicitly
   moon add mypackage --role runtime
   moon add mypackage --dev
   moon add mypackage --tool
   moon add mypackage --helper
   moon add mypackage --peer
   moon add mypackage --optional
   ```

See [Dependency Roles](DEPENDENCY-ROLES.md) for the full role taxonomy and [Glossary](GLOSSARY.md) for term disambiguation.

## 4. For the Brave: Manual Submission

If you prefer to bypass the interactive wizard and have already prepared a `package.toml` (or `package.json`), you can use the **Manual Mode** on the [Registry Wizard](/create/wizard/):

1. Go to the **Identity** step.
2. Click **"Brave Mode: Upload Manifest"**.
3. Select your `package.toml`.
4. The wizard will automatically parse your manifest and populate all subsequent steps (Version, Artifact, Storage).
5. Review the imported data in the final step and click **Publish**.

This is the fastest way to register multiple artifacts or complex packages with custom materialization rules.
