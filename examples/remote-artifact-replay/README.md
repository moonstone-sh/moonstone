# Moonstone Exact Remote Artifact Retrieval Example

This example demonstrates Moonstone's exact remote artifact recovery mechanism:

```text
local CAS
→ configured remote artifact providers
→ materializer-specific source rematerialization
→ precise terminal failure
```

Key guarantees:
- **Keyed by exact `artifact_hash`**: Remote retrieval fetches exact target realizations by `artifact_hash` without package manager resolution.
- **Local verification**: Downloads are extracted into secure staging and verified against `artifact_hash` before atomic commit.
- **Offline enforcement**: In offline mode (`--offline`), remote HTTP providers are bypassed entirely.
