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
  process smoke coverage; still experimental due to symlink and filesystem
  atomic rename constraints.*
- Windows GNU ARM64 (`aarch64-windows-gnu`) - *Compile-time and release-matrix
  coverage. Native Windows-on-ARM execution coverage remains to be added.*
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
