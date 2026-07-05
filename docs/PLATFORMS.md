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

## Tier 2 (Compiles from Source)

These targets are not officially distributed in binary form, but can be compiled from source using the Zig toolchain (`zig build`). 

- Windows (`x86_64-windows`) - *Currently experimental due to symlink and filesystem atomic rename constraints.*
- Linux / Musl (`x86_64-linux-musl`, `aarch64-linux-musl`) - *Fully supported by Zig, ideal for ultra-minimalist distros.*

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
