# Exact Artifact Publication and Registry Retention Example

This example demonstrates Moonstone's exact remote artifact publication protocol:

```text
materialize or retrieve artifact
→ verify local artifact_hash
→ encode canonical transport object (moonstone:artifact-transport:v1)
→ publish idempotently by artifact_hash
→ registry validates and stores immutable object
→ another machine retrieves by artifact_hash
```

## Key Guarantees

- **Explicit Target Identity**: `ArtifactRequest` and `ArtifactPublishRequest` require explicit concrete target identities (e.g. `aarch64-macos`), eliminating context-sensitive `native` defaults.
- **Idempotent Storage**: Repeated publication of the same verified `artifact_hash` returns `already_present`, never overwriting existing objects.
- **Retention Roots & Associations**: Artifacts are associated with retention roots (`published_package_version`, `active_release`, `manual_pin`) to prevent cache eviction from invalidating public lockfiles.

## Project Files

- `moonstone.toml`: Project manifest defining dependencies.
- `moonstone.lock`: Lockfile recording exact `artifact_hash` realizations and target profiles.
- `publish.sh`: Shell script demonstrating artifact encoding and publication steps.

## Usage

```bash
# Make script executable
chmod +x publish.sh

# Execute artifact publication workflow
./publish.sh
```
