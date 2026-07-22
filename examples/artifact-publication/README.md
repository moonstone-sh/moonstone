# Moonstone Exact Artifact Publication and Registry Retention Example

This example demonstrates Moonstone's exact remote artifact publication protocol:

```text
materialize or retrieve artifact
→ verify local artifact_hash
→ encode canonical transport object (moonstone:artifact-transport:v1)
→ publish idempotently by artifact_hash
→ registry validates and stores immutable object
→ another machine retrieves by artifact_hash
```

Key guarantees:
- **No `native` Default Target**: `ArtifactRequest` and `ArtifactPublishRequest` require explicit concrete target identities.
- **Idempotent Storage**: Repeated publication of the same verified `artifact_hash` is idempotent (`already_present`), never overwriting existing objects.
- **Retention Roots & Associations**: Artifacts are associated with retention roots (`published_package_version`, `active_release`, `manual_pin`) to prevent cache eviction from invalidating public lockfiles.
