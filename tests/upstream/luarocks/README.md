# LuaRocks Rockspec Parser Corpus

This directory pins every `.rockspec` fixture from LuaRocks upstream revision
`665f160b4d0b79e85e66c6cc83e442d72eb40868` (retrieved on August 8, 2026),
plus Moonstone-owned schema fixtures for legal declaration fields and
versioned validation boundaries that upstream's fixture tree does not cover.

It is not a vendored LuaRocks checkout and Moonstone does not claim to pass the
LuaRocks CLI suite. The upstream suite exercises LuaRocks commands, trees,
administration, packing, upload, and internal Lua modules that Moonstone does
not implement.

The checked-in upstream fixtures are exact byte snapshots. `fixtures.sha256`
is their integrity manifest and `expectations.tsv` records parser outcomes.
`run_conformance.sh` verifies every snapshot, requires expected-valid source to
produce a complete JSON-compatible `document`, rejects the intentionally
malformed Lua fixture, and checks the full versioned declaration surface.

Run locally:

```bash
tests/upstream/luarocks/run_conformance.sh
```

To additionally prove that the snapshots still match a checked-out upstream
repository at the pinned revision:

```bash
LUAROCKS_UPSTREAM_DIR=/path/to/luarocks \
  tests/upstream/luarocks/run_conformance.sh
```

With `LUAROCKS_UPSTREAM_DIR`, the harness also compares every fixture's
accepted, syntax-rejected, or schema-rejected outcome against LuaRocks' own
persisted-rockspec loader and versioned schema.

Run the generated structural mutation matrix against that same pinned checkout:

```bash
LUAROCKS_UPSTREAM_DIR=/path/to/luarocks \
  tests/upstream/luarocks/run_schema_mutation_matrix.sh
```

Run every accepted corpus fixture under Linux, macOS, and Windows platform
selectors against LuaRocks' persisted-loader and build-default behavior:

```bash
LUAROCKS_UPSTREAM_DIR=/path/to/luarocks \
  tests/upstream/luarocks/run_projection_parity.sh
```

Parser coverage is P0 in the compatibility plan. The optional schema and
projection differentials are bounded P1 evidence for validation and resolver
intent alignment; promotion to materialization, execution, or replay
compatibility still requires dedicated evidence for that later level.
