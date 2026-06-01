# Moonstone Registry Model

This document describes how a Moonstone registry is structured, how it scales from a
static file tree to a full web service, and how the Moonstone client consumes it.

The canonical Valibot schemas and TypeScript type definitions live in `moonstone.sh/src/types/schemas.ts`.  This doc
explains the *behavior* and *topology* those structures represent.

---

## Table of Contents

1. [Design Principles](#design-principles)
2. [Registry Topology](#registry-topology)
3. [File Reference](#file-reference)
4. [Basic Registry (Static)](#basic-registry-static)
5. [Mature Registry (Web Service)](#mature-registry-web-service)
6. [Registry API](#registry-api)
7. [Publish Flow](#publish-flow)
8. [Index Rebuild](#index-rebuild)
9. [Blob Storage & Addressing](#blob-storage--addressing)
10. [Authentication & Access Control](#authentication--access-control)
11. [CDN & Edge Caching](#cdn--edge-caching)
12. [Client Resolution Flow](#client-resolution-flow)
13. [Migration Path: Basic → Mature](#migration-path-basic--mature)

---

## Design Principles

1. **Content-addressed blobs** — Every artifact is identified by its hash.  If the
   hash matches, the bytes are correct.  No trust in transport needed.
2. **Immutable descriptors** — A `package.toml` for version `1.2.3` never changes.
   If it needs correction, publish `1.2.4`.
3. **Small, cacheable index** — The package index is a flat list (<1 MB) that the
   client fetches entirely.  It points to lazy-loaded descriptors.
4. **Registry-agnostic client** — The client reads `registry.toml`, then follows
   the URLs and hashes it finds.  It works equally well with a `file://` tree or an
   HTTPS API.
5. **No server-side state per user** — The registry stores packages, not user
   sessions.  Authentication is only for write access or private packages.

---

## Registry Topology

A registry is a tree of static files.  Whether served by nginx, S3, or a Hono app,
the paths are the same.

```
registry/
├── registry.toml                     # Registry metadata + capabilities
├── index.toml                        # Flat list of all package versions
├── packages/
│   └── {name}/
│       └── {version}/
│           └── package.toml          # Full descriptor for that version
└── blobs/
    └── {algo}/
        └── {h0h1}/
            └── {h2h3}/
                └── {hash}.{ext}      # Content-addressed artifact archive
```

### Why this shape?

- **`registry.toml`** is the entry point.  The client fetches it once per session to
  discover the index URL, blob layout, and capabilities.
- **`index.toml`** is the hot path.  It is small, versioned, and aggressively cached.
- **`packages/{name}/{version}/`** isolates descriptors.  A single package version
  descriptor is cheap to fetch lazily.
- **`blobs/`** uses sharding (`{algo}/{h0h1}/{h2h3}/`) to avoid putting millions of
  files in one directory.  This matters for S3, local ext4, and CDN origin pulls.

---

## File Reference

### `registry.toml`

Top-level metadata.  The client reads this first.

```toml
[registry]
id = "moonstone-v0"
name = "Moonstone Official Registry"
protocol = "moonstone.registry.v0"
revision = 42
generated_at = "2026-05-17T00:00:00Z"
min_client = "0.1.0"

[index]
format = "toml"
url = "https://moonstone.sh/registry/v0/index.toml"
hash = "b3:abc123..."
bytes = 1048576
revision = 42

[blobs]
algorithm = "blake3"
layout = "shard"

[capabilities]
runtimes = true
artifacts = true
source_packages = true
rocks_bridge = false
private = false
```

**Important fields:**
- `registry.protocol` — must be `"moonstone.registry.v0"`.  The client rejects
  unknown protocols so we can evolve safely.
- `index.hash` — Blake3 hash of `index.toml`.  The client verifies it after
  download.  If it mismatches, the client treats the registry as corrupted.
- `capabilities.private` — if `true`, the client must send an `Authorization` header.

### `index.toml`

A flat array of every published package version.

```toml
[[package]]
name = "inspect"
version = "3.1.3"
kind = "lib"
descriptor = "packages/inspect/3.1.3/package.toml"
descriptor_hash = "b3:..."
targets = ["native"]
runtimes = ["lua54"]
```

The client downloads the entire index, then resolves dependencies locally against
this list.  No server-side query engine is required.

### `packages/{name}/{version}/package.toml`

Full descriptor.  Fetched lazily, only when the client decides to install.

```toml
[package]
name = "inspect"
version = "3.1.3"
kind = "lib"
description = "Human-readable representation of Lua tables"

[compat]
runtimes = ["lua54"]

[[artifact]]
target = "native"
lua_abi = "lua54"
url = "https://moonstone.sh/registry/blobs/b3/aa/bb/...tar.gz"
hash = "b3:..."
format = "tar.gz"
bytes = 15360

[artifact.layout]
strip_components = 0

[artifact.provides]
runtime = []
bin = []
headers = []
native_lib = []
```

The `artifact` array can contain multiple entries for different targets.  The
client picks the one whose `target` matches the host and whose `lua_abi` matches
the project's runtime.

### `blobs/{algo}/{shard}/{hash}.{ext}`

The actual artifact bytes.  Addressed by content hash.  The client verifies the
hash after download.

---

## Basic Registry (Static)

A basic registry is just a directory tree.  You can serve it with:

- `python -m http.server`
- `npx serve`
- nginx with `autoindex off`
- S3 static website hosting
- GitHub Pages

### Setup

1. Create the topology above.
2. Run `moonstone index rebuild` (or a small script) to regenerate `index.toml`.
3. Point `moonstone.toml` at it:

```toml
[registries.synthetic]
path = "./fixtures/sandbox/registry"
```

### Trade-offs

| Pros | Cons |
|------|------|
| Zero backend code | No upload API — you rsync or git-push files |
| Works offline via `file://` | No authentication or access control |
| Cache-friendly (immutable blobs) | No analytics, rate limits, or abuse prevention |
| Easy to mirror (rsync, rclone) | Index is monolithic; large registries have a big index |

A static registry is perfect for:
- Corporate intranets with CI-generated artifacts.
- Air-gapped environments.
- Testing and synthetic playgrounds.

---

## Mature Registry (Web Service)

A mature registry adds a thin API layer on top of the static file tree.  The files
are still the source of truth; the API is a convenience wrapper.

### Architecture

```
┌─────────────────┐     ┌──────────────┐     ┌─────────────────┐
│   moon client   │────▶│  Registry    │────▶│  Blob Store     │
│                 │     │  API (Hono)    │     │  (S3 / R2 / FS) │
└─────────────────┘     └──────────────┘     └─────────────────┘
                              │
                              ▼
                        ┌──────────────┐
                        │  Index DB    │
                        │  (SQLite)    │
                        └──────────────┘
```

### Responsibilities

| Layer | What it does |
|-------|-------------|
| **Registry API** | Auth, upload validation, index rebuild orchestration, search |
| **Blob Store** | Immutable object storage.  The API forwards upload URLs. |
| **Index DB** | Fast lookups for search, webhooks, and index rebuilds.  Not the source of truth — `index.toml` is. |

### Why not serve everything from a database?

Because the client already knows how to read static files.  A database is only for
operational convenience (search, auth, webhooks).  The client still downloads
`registry.toml`, `index.toml`, descriptors, and blobs exactly as it does from a
static registry.

---

## Registry API

### Endpoints

A mature registry exposes the following endpoints.  All paths are prefixed by the
registry URL (e.g. `https://moonstone.sh/registry/v0`).

#### Read endpoints (public or token-scoped)

| Method | Path | Purpose | Returns |
|--------|------|---------|---------|
| `GET` | `/registry.toml` | Registry metadata | `RegistryRoot` |
| `GET` | `/index.toml` | Package index | `RemotePackageIndex` |
| `GET` | `/packages/:name/:version/package.toml` | Descriptor | `RemotePackageDescriptor` |
| `GET` | `/blobs/:algo/:shard/:hash.:ext` | Artifact bytes | Raw archive |
| `GET` | `/search?q=inspect` | Search packages | `SearchResponse` |

#### Write endpoints (authenticated)

| Method | Path | Purpose | Body | Returns |
|--------|------|---------|------|---------|
| `POST` | `/publish` | Stage a new package | `PublishRequest` | `PublishResponse` |
| `POST` | `/publish/:hash/complete` | Confirm blob upload | — | `PublishResponse` |
| `POST` | `/admin/rebuild` | Force index rebuild | — | `{ revision: number }` |

### Authentication

The client sends:

```http
Authorization: Bearer <token>
```

Tokens are scoped per-registry in `moonstone.toml`:

```toml
[registries.moonstone]
url = "https://moonstone.sh/registry/v0"
token = "mst_..."
```

A mature registry validates tokens and returns `401` for missing/invalid tokens
when `capabilities.private = true`.  For public registries, tokens are optional
but may unlock higher rate limits.

### Search

The search endpoint is the only read endpoint that requires server-side state:

```http
GET /search?q=inspect&kind=lib&runtime=lua54&limit=20
```

Response:

```json
{
  "results": [
    {
      "name": "inspect",
      "version": "3.1.3",
      "kind": "lib",
      "description": "Human-readable representation of Lua tables",
      "runtimes": ["lua54"],
      "targets": ["native"]
    }
  ],
  "total": 1,
  "offset": 0,
  "limit": 20
}
```

Search is optional.  A basic registry simply does not implement it; the client
falls back to local index filtering.

---

## Publish Flow

Publishing a package to a mature registry is a two-phase process:

### Phase 1: Upload descriptor + blob metadata

```http
POST /publish
Content-Type: application/json
Authorization: Bearer <token>

{
  "descriptor": { ...RemotePackageDescriptor... },
  "blob": {
    "hash": "b3:abc123...",
    "bytes": 15360,
    "format": "tar.gz"
  }
}
```

The registry:
1. Validates the descriptor (name, version, kind, artifact hashes).
2. Checks that the version does not already exist.
3. Returns a pre-signed upload URL for the blob:

```json
{
  "ok": true,
  "message": "Upload the blob to the provided URL",
  "upload_url": "https://blob.moonstone.sh/b3/aa/bb/abc123.tar.gz?X-Amz-...",
  "expires_at": "2026-05-17T01:00:00Z"
}
```

### Phase 2: Upload blob

The client PUTs the blob bytes to `upload_url`.  The blob store verifies the
`Content-Length` and `Content-Hash` headers.

### Phase 3: Confirm

```http
POST /publish/b3:abc123/complete
Authorization: Bearer <token>
```

The registry:
1. Verifies the blob exists in storage.
2. Writes `packages/{name}/{version}/package.toml`.
3. Triggers an asynchronous index rebuild.
4. Returns the new index revision.

```json
{
  "ok": true,
  "message": "inspect 3.1.3 published",
  "revision": 43
}
```

### Static registry alternative

For a basic registry, publishing is just:

```bash
# Build the artifact
moon build

# Copy files into the registry tree
cp dist/inspect-3.1.3.tar.gz registry/blobs/b3/aa/bb/abc123.tar.gz
cp dist/package.toml registry/packages/inspect/3.1.3/package.toml

# Rebuild the index
moonstone index rebuild registry/
```

---

## Index Rebuild

The index is rebuilt whenever a package is published or yanked.

### Algorithm

1. Walk `packages/*/*/package.toml`.
2. Parse each descriptor, extracting `name`, `version`, `kind`, `targets`, `runtimes`.
3. Compute the descriptor hash (blake3 of the file bytes).
4. Sort by `(name, version)` for deterministic output.
5. Write `index.toml`.
6. Compute `index.toml` hash.
7. Update `registry.toml` with the new `index.hash` and `revision`.

### Determinism

The index must be bit-for-bit reproducible given the same set of descriptors.
This means:
- Deterministic sorting.
- No timestamps inside `index.toml`.
- No OS-specific path separators in descriptor paths.

### Webhooks

A mature registry can notify mirrors and caches after rebuild:

```json
{
  "event": "index.rebuilt",
  "registry": { ...RegistryMetadata... },
  "index": { ...IndexMetadata... }
}
```

Subscribers re-fetch `registry.toml`, compare `revision`, and pull the new
`index.toml` if needed.

---

## Blob Storage & Addressing

### Hash algorithm

Moonstone v0 uses **Blake3** as the default hash algorithm.  Blake3 is fast,
parallelizable, and produces 256-bit hashes that fit comfortably in URLs and
filenames.

### Shard layout

```
blobs/b3/aa/bb/abcd...ef01.tar.gz
      │  │  │
      │  │  └── Third and fourth hex characters
      │  └───── First and second hex characters
      └──────── Hash algorithm prefix
```

This creates at most `256 × 256 = 65 536` leaf directories.  Even with millions
of artifacts, each leaf holds <200 files — well within the comfort zone of
ext4, XFS, and S3.

### Storage backends

| Backend | Pros | Cons |
|---------|------|------|
| Local filesystem | Zero cost, trivial setup | No replication, limited by disk |
| S3 / R2 | Infinite scale, CDN-friendly | Latency, egress costs |
| IPFS | Decentralized, deduplication | Slower, requires gateway |

The registry API abstracts the backend.  The client only sees URLs.

### Content verification

The client always verifies the hash after download:

```zig
var hash_buf: [32]u8 = undefined;
std.crypto.hash.Blake3.hash(downloaded_bytes, &hash_buf, .{});
const actual = std.fmt.bytesToHex(hash_buf, .lower);
// compare actual to descriptor.artifact.hash
```

If the hash mismatches, the artifact is discarded and the install fails.

---

## Authentication & Access Control

### Public registries

- No token required for reads.
- Token optional for rate-limit bypass.
- Token required for writes (`POST /publish`).

### Private registries

- `capabilities.private = true` in `registry.toml`.
- Token required for all reads and writes.
- The client sends `Authorization: Bearer <token>` on every request.
- Token scopes:
  - `read` — fetch descriptors and blobs.
  - `write` — publish packages.
  - `admin` — rebuild index, manage tokens.

### Token format

Moonstone tokens are opaque strings prefixed by the registry ID:

```
mst_v0_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

The registry validates tokens against its internal database.  The client treats
them as opaque strings.

---

## CDN & Edge Caching

### Cache rules

| File | TTL | Cache key | Notes |
|------|-----|-----------|-------|
| `registry.toml` | 60 s | URL | Changes only on index rebuild |
| `index.toml` | 300 s | URL + revision | Immutable once published |
| `package.toml` | forever | URL | Never changes |
| `blobs/*` | forever | URL + hash | Content-addressed, truly immutable |

### Cache invalidation

Because `package.toml` and blobs are immutable, you never invalidate them.  You
only invalidate `registry.toml` (short TTL) and `index.toml` (medium TTL, or
use the `revision` query param).

### Edge-friendly design

The static file topology is designed to work with any CDN:

1. CloudFront / Cloudflare / Fastly sits in front of the registry API.
2. The CDN caches blobs forever.
3. The CDN caches descriptors forever.
4. The CDN caches the index for 5 minutes, or until `registry.toml` changes.
5. Uploads go directly to the origin (or pre-signed S3 URLs), bypassing the CDN.

---


## Compact SQLite Index

For large registries, a flat `index.toml` becomes slow to parse. Moonstone v0
supports an optional compressed SQLite snapshot:

```
registry/
  registry.toml
  index.toml              # fallback / debug
  index.sqlite.zst        # compact resolver index
  packages/
  blobs/
```

### registry.toml fields

```toml
[index.compact]
format = "sqlite-zstd"
url = "index.sqlite.zst"
compressed_hash = "b3:..."       # BLAKE3 of the .zst file
compressed_bytes = 45678
content_hash = "b3:..."          # BLAKE3 of the decompressed SQLite
content_bytes = 234567
revision = 42
```

### Client behavior

1. If `[index.compact]` exists, download `index.sqlite.zst`.
2. Verify `compressed_hash` against the downloaded bytes.
3. Decompress with `zstd` to a temporary `index.sqlite.tmp`.
4. Verify `content_hash` against the decompressed bytes.
5. Atomically rename `index.sqlite.tmp` -> `index.sqlite`.
6. Use SQLite for resolver queries (versions, artifacts, provides).
7. If compact index is missing or fails, fall back to `index.toml`.

### SQLite schema

```sql
CREATE TABLE packages (
  name TEXT NOT NULL,
  version TEXT NOT NULL,
  kind TEXT NOT NULL,
  descriptor TEXT NOT NULL,
  descriptor_hash TEXT NOT NULL,
  yanked INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (name, version)
);

CREATE TABLE artifacts (
  name TEXT NOT NULL,
  version TEXT NOT NULL,
  artifact_hash TEXT NOT NULL,
  target TEXT,
  lua_abi TEXT,
  url TEXT NOT NULL,
  bytes INTEGER,
  format TEXT NOT NULL,
  PRIMARY KEY (name, version, artifact_hash)
);

CREATE TABLE provides_lua (
  artifact_hash TEXT NOT NULL,
  module TEXT NOT NULL,
  path TEXT NOT NULL,
  lua_abi TEXT,
  PRIMARY KEY (artifact_hash, module)
);
```

---

## Deterministic Tarballs

Moonstone artifact hashes are reproducible. The registry builder normalizes:

- Sorted lexicographic path order
- mtime = 0, uid/gid = 0, uname/gname = ""
- Directories mode 0755, regular files mode 0644 (binaries 0755)
- gzip mtime = 0

This ensures that building the same artifact twice produces the same artifact_hash.

---

## Source Hash vs Artifact Hash

Moonstone tracks two distinct hashes for provenance:

| Hash | What it identifies | Optional? |
|------|-------------------|-----------|
| source_hash | Raw upstream tarball (e.g., lua-5.4.7.tar.gz from lua.org) | Yes |
| recipe_hash | Canonical materialization recipe (schema, name, version, materializer, layout, provides) | No |
| artifact_hash | Final Moonstone artifact tarball (deterministic, repackaged) | No |

The chain in the lockfile:

```
registry.toml -> index.toml -> package.toml -> artifact blob
                    |              |                |
              descriptor_hash  recipe_hash    artifact_hash
```

recipe_hash is always required because every artifact came from some plan,
even if that plan is trivial ("unpack this prebuilt blob").

---

## Client Resolution Flow

When the user runs `moon add inspect` or `moon sync`:

```
1. Parse package spec → detect resolver prefix (moonstone:, rocks:, path:, link:)
2. If prefixed → use that resolver only.
   If unprefixed → read [resolution] default_order from moonstone.toml
                   (default: moonstone → rocks)
3. For moonstone resolver:
   a. Read moonstone.toml → find registry URLs / paths.
   b. Fetch registry.toml from each registry.
   c. Fetch index.toml (or use local cache if revision matches).
   d. Resolve version ranges against the index.
   e. Fetch package.toml (lazy, only if installing).
   f. Select artifact matching host target + lua_abi.
   g. Check local store for artifact_hash.
   h. If missing, download blob from registry.
   i. Verify blob hash.
   j. Unpack blob into store/artifacts/{hash}/.
   k. Write store/manifests/{hash}.toml.
4. For rocks resolver:
   a. Fetch LuaRocks manifest (e.g. manifest-5.4.json) for the active runtime.
   b. Look up package name and select the newest version with a source rockspec.
   c. Fetch rockspec from LuaRocks.
   d. Parse and normalize into Moonstone descriptor.
   e. Download .src.rock, unpack, and materialize Lua modules.
   f. Store artifact in Moonstone store.
5. For path resolver:
   a. Read moonstone.toml at the target path.
   b. Return local-path candidate (no download).
6. For link resolver:
   a. Look up global link registry.
   b. Return registered path candidate (no download).
7. Rebuild local index from store manifests.
8. Generate .moonstone/env symlinks.
```

For linked dependencies (`path:`, `link:`), steps 3–4 are skipped; the env
symlinks point directly to the source project.

### Resolver Kinds

| Prefix | Resolver | Source recorded in lockfile |
|--------|----------|----------------------------|
| (none) | `default_order` | `moonstone:<name>` or `rocks:<name>` |
| `moonstone:` | Moonstone registry | `moonstone:<name>` |
| `rocks:` | LuaRocks importer | `rocks:<name>` |
| `path:` | Local filesystem | `path:<path>` |
| `link:` | Global link registry | `link:<name>` |

The lockfile records both `resolver` (which resolver produced the entry) and
`source` (the canonical origin string) so that `moon sync` can replay
resolution deterministically.

---

## Migration Path: Basic → Mature

A team can start with a static registry and graduate to a web service without
changing the client:

| Stage | Setup | Why |
|-------|-------|-----|
| **1. Local static** | `file://./registry` | Development, testing |
| **2. Shared static** | S3 + nginx | Team sharing, CI |
| **3. API gateway** | Hono app proxies to S3 | Auth, search, analytics |
| **4. Full service** | Upload API, webhooks, CDN | Public registry scale |

At every stage, the file topology remains identical.  The API is an additive
layer, not a replacement.

---

## Summary

A Moonstone registry is a content-addressed file tree.  The simplest version is a
folder on disk.  The most sophisticated version is a CDN-backed web service with
auth, search, and upload APIs.  Both share the same topology, the same hash
verification, and the same client behavior.

The only difference is how files get there.

---

## Compact SQLite Index

For large registries, a TOML `index.toml` can become unwieldy.  Moonstone supports an optional compact index:

```
registry/
  registry.toml
  index.toml              # fallback / debug
  index.sqlite.zst        # compact index (optional)
  packages/
  blobs/
```

### `registry.toml` fields

```toml
[index.compact]
format = "sqlite-zstd"
url = "index.sqlite.zst"
compressed_hash = "b3:..."
compressed_bytes = 45678
content_hash = "b3:..."
content_bytes = 234567
revision = 42
```

### Client behavior

1. If `[index.compact]` is present, download `index.sqlite.zst`.
2. Verify `compressed_hash`.
3. Decompress to `index.sqlite` in local registry cache.
4. Verify `content_hash` if provided.
5. Open SQLite and use it for package/version/artifact queries.
6. Fall back to `index.toml` if compact index is absent or unsupported.

### Registry builder

The builder can generate both `index.toml` and `index.sqlite.zst`.  The SQLite schema covers packages, artifacts, and provisions so the resolver can answer:

- Which versions of `inspect` exist?
- Which artifact provides `require("inspect")`?
- Which runtime artifacts support `x86_64-freebsd`?

**Status:** The compact SQLite index is implemented in `registry.zig` via `fetch_compact_index` and is now actively wired into `resolver.zig`. The resolver queries the compact index first and seamlessly falls back to the TOML index if the compact version is unavailable or fails.
