# Moonstone Multi-Platform Example

This example demonstrates how Moonstone lockfiles express target/runtime resolution profiles for multi-platform projects:

- **Explicit Profile Creation**: New platforms are added via explicit profile generation operations.
- **Frozen Replay**: Replaying an existing lockfile matches the active target/runtime profile and performs frozen replay without re-resolving or mutating existing profiles.
- **Target-Specific Realizations**: Each package realization records exact recipe, plan, and artifact hashes.
