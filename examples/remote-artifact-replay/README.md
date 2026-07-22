# Clean-Store Remote Artifact Replay Example

This example demonstrates Moonstone's clean-store lockfile replay pipeline for compiled native modules (`declared_host` assurance).

## Recovery Pipeline

When replaying `moonstone.lock` on a clean machine (where `~/.moonstone/store/` has no cached copy of `lpeg`), Moonstone follows the exact recovery priority:

1. **Local CAS Lookup**: Search local store by `artifact_hash`.
2. **Remote Artifact Provider**: Fetch pre-built artifact by exact `artifact_hash` (`b3:87102fba...`) from configured artifact registry.
3. **CAS Commit & Environment Projection**: Verify tar/zst payload against `artifact_hash` and commit to local CAS.
4. **Strict Replay Invariant**: Native packages marked `declared_host` require exact pre-built artifacts, preventing arbitrary local host toolchain drift during frozen replay.

## Project Files

- `moonstone.toml`: Manifest declaring `rocks:lpeg` dependency.
- `moonstone.lock`: Lockfile storing `artifact_hash`, `plan_schema`, `plan_hash`, and `declared_host` assurance level.
- `main.lua`: Test script validating `lpeg` C module execution.

## Usage

```bash
# Clean local store to simulate a clean machine
moon store purge --confirm

# Synchronize using clean-store remote artifact recovery
moon sync --locked

# Execute application using restored binary module
moon run main.lua
```
