# Moonstone Platform Matrix

Moonstone is written in [Zig](https://ziglang.org), which provides incredible cross-compilation capabilities out of the box. Moonstone is officially built and distributed for the following architectures and operating systems.

## Tier 1 (Officially Supported & Distributed)

These targets are automatically tested and released as pre-compiled binaries via GitHub Releases, DockerHub, Homebrew, and Nix.

| OS | Architecture | Target String | CI/CD Distribution |
|---|---|---|---|
| Linux | x86_64 | `x86_64-linux` | GitHub, Docker (amd64), Nix, Homebrew |
| Linux | ARM64 | `aarch64-linux` | GitHub, Docker (arm64), Nix, Homebrew |
| macOS | ARM64 (Apple Silicon) | `aarch64-macos` | GitHub, Nix, Homebrew |
| macOS | x86_64 (Intel) | `x86_64-macos` | GitHub, Nix, Homebrew |
| FreeBSD | x86_64 | `x86_64-freebsd` | GitHub |
| FreeBSD | ARM64 | `aarch64-freebsd` | GitHub |

## Tier 2 (Experimental / Partial Native Certification)

These targets have a bounded support contract. They compile through the release
matrix and are published as GitHub Release artifacts, but native execution
coverage is still incomplete for the architectures noted below.

- Windows GNU (`x86_64-windows-gnu`) - *Native `windows-latest` projection and
  process smoke coverage. Enabling Developer Mode is strongly recommended for
  unprivileged symlink creation; fallback handling exists when symlinks are restricted,
  though native symlinks remain preferred.*
- Windows GNU ARM64 (`aarch64-windows-gnu`) - *Compile-time and release-matrix
  coverage. Native Windows-on-ARM execution coverage remains to be added.*
- Linux / Musl (`x86_64-linux-musl`, `aarch64-linux-musl`) - *Fully supported by Zig, ideal for ultra-minimalist distros.*

## Native Lua Modules and the Lua C API

A native Lua module (builtin, make, command or CMake rock, or a Moonstone C
module) never carries its own copy of the Lua runtime. It uses the C API of
the process that loads it: Moonstone's `lua`/`luajit`, or a host such as
Neovim, LÖVE or OpenResty.

| Target | How the module gets `lua_*` / `luaL_*` |
| --- | --- |
| Linux, BSD (ELF) | Left undefined; resolved from the loading process at `require` time. |
| macOS (Mach-O) | `-undefined dynamic_lookup`; resolved from the loading process. |
| Windows (PE) | Linked against the runtime's Lua import library. |

Consequences:

- Moonstone's ELF runtime executables export the Lua C API dynamically. A
  custom runtime package must do the same (link with `-Wl,-E` or ship a shared
  `liblua`), or its native modules fail to load with undefined-symbol errors.
- Modules that ship compatibility definitions of runtime functions (for
  example `luaL_setfuncs` or `luaL_testudata` from compat-5.3, as `luasystem`
  does) build normally.
- A module built for a runtime's ABI loads in any host with that ABI; for
  example, `luajit@2.1` modules load inside Neovim.

Covered by `tests/e2e/build/luarocks_cmodule_host_symbols_contract.sh`.

## Native Ecosystem Packages

### Homebrew (macOS / Linux)
Moonstone provides a custom Homebrew tap.
```bash
brew install moonstone-sh/tap/moonstone
```

### Nix (Linux / macOS)
Moonstone exposes a native `flake.nix`.
```bash
nix profile install github:moonstone-sh/moonstone
```
Or for ephemeral testing:
```bash
nix shell github:moonstone-sh/moonstone
```

### Docker
Official multi-arch containers are available on DockerHub.
```bash
docker pull moonstonesh/moonstone:alpine
docker pull moonstonesh/moonstone:ubuntu
```
