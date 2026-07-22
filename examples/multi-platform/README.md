# Multi-Platform Resolution Profiles Example

This example demonstrates Moonstone's target-specific resolution profiles (`ResolutionProfile`) inside a single `moonstone.lock` lockfile.

## Lockfile Features

- **Coexisting Target Profiles**: Contains `aarch64-macos+lua-5.4+5.4` and `x86_64-linux+lua-5.4+5.4` resolution profiles in one lockfile.
- **Frozen Replay**: Running `moon sync --locked` on macOS or Linux selects the matching target profile without re-resolving dependencies or modifying `moonstone.lock`.
- **Append-Only Profile Creation**: Running `moon sync --add-profile <target>` appends a new profile transactionally without mutating existing platform realizations.

## Project Files

- `moonstone.toml`: Project manifest defining dependencies.
- `moonstone.lock`: Multi-profile lockfile storing exact realizations and target profiles.
- `main.lua`: Application entry point.

## Usage

```bash
# Run frozen replay using existing profile
moon sync --locked

# Run main script
moon run main.lua

# Append a new platform target profile (e.g. x86_64-windows-msvc)
moon sync --add-profile x86_64-windows-msvc
```
