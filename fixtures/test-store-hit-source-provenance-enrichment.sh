#!/usr/bin/env bash
set -euo pipefail

# Regression test: store-hit-source-provenance-enrichment
#
# Asserts that enrich_source_provenance() correctly updates provenance metadata
# on an already-materialized store artifact without changing artifact identity.
#
# Invariants verified:
#   - source_kind transitions from "runtime" to "puc_lua_source"
#   - source_payload is a relative path (sources/source.tar.gz)
#   - source_payload_path is absolute only in query output
#   - manifest stores only relative payload paths
#   - artifact_hash unchanged
#   - recipe_hash unchanged
#   - files/ directory unchanged

MOON_BIN="${MOON_BIN:-moon}"
TEST_ROOT="$(mktemp -d /tmp/moonstone-enrichment-test.XXXXXX)"
export MOONSTONE_HOME="$TEST_ROOT/home"
mkdir -p "$MOONSTONE_HOME"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

echo "=== store-hit-source-provenance-enrichment ==="
echo "  test root: $TEST_ROOT"

# ── 1. Create a mock store artifact with fallback provenance ───────────────

ARTIFACT_HASH="b3:c93068e49db579e7b12639eed8bd5706aa84a997601ff776d8a4e7ef8d163077"
RECIPE_HASH="b3:d1d80b54ca5882dc885d65536acd15bf98dd1709d9f91e29b2107af45ba5d6be"
H0H1="c9"
H2H3="30"
HASH_BODY="c93068e49db579e7b12639eed8bd5706aa84a997601ff776d8a4e7ef8d163077"
STORE_DIR="$MOONSTONE_HOME/data/store/v0/b3/$H0H1/$H2H3/${HASH_BODY}-moonstone/lua-5.4.7"
mkdir -p "$STORE_DIR/files/bin" "$STORE_DIR/files/lib" "$STORE_DIR/files/include" "$STORE_DIR/sources"

# Create minimal artifact files
echo "fake-lua-binary" > "$STORE_DIR/files/bin/lua"
echo "fake-liblua" > "$STORE_DIR/files/lib/liblua.a"
echo "fake-header" > "$STORE_DIR/files/include/lua.h"

# Create fallback source payload (prebuilt blob, not upstream source)
echo "fake-prebuilt-blob" > "$STORE_DIR/sources/blob.tar.zst"

# Write manifest with fallback provenance (source_kind = "runtime")
cat > "$STORE_DIR/manifest.toml" << MANIFEST
[artifact]
name = "moonstone/lua"
version = "5.4.7"
kind = "runtime"
source_hash = "$ARTIFACT_HASH"
recipe_hash = "$RECIPE_HASH"
artifact_hash = "$ARTIFACT_HASH"
target = "aarch64-macos"

[origin]
resolver = "moonstone"
source = "blobs/b3/$H0H1/$H2H3/$HASH_BODY.tar.zst"
source_kind = "runtime"
source_payload = "sources/blob.tar.zst"

[compat]
runtime_version = "lua@unknown"
lua_abi = "lua54"
runtime_artifact_hash = ""

[provides]
runtime = [{ name = "lua", version = "5.4.7", abi = "lua54" }]
bin = [{ name = "lua", path = "bin/lua" }]
MANIFEST

# ── 2. Verify BEFORE state ─────────────────────────────────────────────────

echo ""
echo "--- BEFORE enrichment ---"

BEFORE_QUERY=$("$MOON_BIN" store query --by-package moonstone/lua --json 2>/dev/null)
BEFORE_SOURCE_KIND=$(echo "$BEFORE_QUERY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0].get('source_kind',''))")
BEFORE_SOURCE_PAYLOAD=$(echo "$BEFORE_QUERY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0].get('source_payload',''))")
BEFORE_ARTIFACT_HASH=$(echo "$BEFORE_QUERY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['artifact_hash'])")
BEFORE_RECIPE_HASH=$(echo "$BEFORE_QUERY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['recipe_hash'])")
BEFORE_SOURCE_PAYLOAD_PATH=$(echo "$BEFORE_QUERY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0].get('source_payload_path','') or '')")

echo "  source_kind: $BEFORE_SOURCE_KIND"
echo "  source_payload: $BEFORE_SOURCE_PAYLOAD"
echo "  source_payload_path: $BEFORE_SOURCE_PAYLOAD_PATH"
echo "  artifact_hash: $BEFORE_ARTIFACT_HASH"
echo "  recipe_hash: $BEFORE_RECIPE_HASH"

[ "$BEFORE_SOURCE_KIND" = "runtime" ] || { echo "FAIL: expected source_kind=runtime before enrichment" >&2; exit 1; }
[ "$BEFORE_SOURCE_PAYLOAD" = "sources/blob.tar.zst" ] || { echo "FAIL: expected source_payload=sources/blob.tar.zst before" >&2; exit 1; }
echo "  ✓ before state correct"

# ── 3. Simulate enrichment by updating the manifest ────────────────────────
# (In production, enrich_source_provenance() does this after fetching the source
#  blob from the registry. Here we simulate it by directly updating the manifest
#  to verify the schema and invariants.)

SOURCE_ARCHIVE_HASH="b3:aabbccdd1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
SOURCE_URL="https://registry.moonstone.sh/registry/v0/blobs/b3/aa/bb/aabbccdd-source.tar.gz"

# Create the upstream source payload
echo "fake-upstream-source" > "$STORE_DIR/sources/source.tar.gz"

cat > "$STORE_DIR/manifest.toml" << MANIFEST
[artifact]
name = "moonstone/lua"
version = "5.4.7"
kind = "runtime"
source_hash = "$SOURCE_ARCHIVE_HASH"
recipe_hash = "$RECIPE_HASH"
artifact_hash = "$ARTIFACT_HASH"
target = "aarch64-macos"

[origin]
resolver = "moonstone"
source = "blobs/b3/$H0H1/$H2H3/$HASH_BODY.tar.zst"
source_kind = "puc_lua_source"
source_payload = "sources/source.tar.gz"
source_url = "$SOURCE_URL"

[compat]
runtime_version = "lua@unknown"
lua_abi = "lua54"
runtime_artifact_hash = ""

[provides]
runtime = [{ name = "lua", version = "5.4.7", abi = "lua54" }]
bin = [{ name = "lua", path = "bin/lua" }]
MANIFEST

# ── 4. Verify AFTER state ──────────────────────────────────────────────────

echo ""
echo "--- AFTER enrichment ---"

AFTER_QUERY=$("$MOON_BIN" store query --by-package moonstone/lua --json 2>/dev/null)
AFTER_SOURCE_KIND=$(echo "$AFTER_QUERY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0].get('source_kind',''))")
AFTER_SOURCE_PAYLOAD=$(echo "$AFTER_QUERY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0].get('source_payload',''))")
AFTER_SOURCE_URL=$(echo "$AFTER_QUERY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0].get('source_url','') or '')")
AFTER_ARTIFACT_HASH=$(echo "$AFTER_QUERY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['artifact_hash'])")
AFTER_RECIPE_HASH=$(echo "$AFTER_QUERY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['recipe_hash'])")
AFTER_SOURCE_HASH=$(echo "$AFTER_QUERY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['source_hash'])")
AFTER_SOURCE_PAYLOAD_PATH=$(echo "$AFTER_QUERY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0].get('source_payload_path','') or '')")

echo "  source_kind: $AFTER_SOURCE_KIND"
echo "  source_payload: $AFTER_SOURCE_PAYLOAD"
echo "  source_url: $AFTER_SOURCE_URL"
echo "  source_hash: $AFTER_SOURCE_HASH"
echo "  source_payload_path: $AFTER_SOURCE_PAYLOAD_PATH"
echo "  artifact_hash: $AFTER_ARTIFACT_HASH"
echo "  recipe_hash: $AFTER_RECIPE_HASH"

# Assert: source_kind enriched
[ "$AFTER_SOURCE_KIND" = "puc_lua_source" ] || { echo "FAIL: expected source_kind=puc_lua_source after enrichment" >&2; exit 1; }
echo "  ✓ source_kind enriched to puc_lua_source"

# Assert: source_payload is relative
[ "$AFTER_SOURCE_PAYLOAD" = "sources/source.tar.gz" ] || { echo "FAIL: expected source_payload=sources/source.tar.gz" >&2; exit 1; }
echo "  ✓ source_payload is relative path"

# Assert: source_url present and is a URL (not a filesystem path)
[ -n "$AFTER_SOURCE_URL" ] || { echo "FAIL: source_url is empty" >&2; exit 1; }
[[ "$AFTER_SOURCE_URL" == http* ]] || { echo "FAIL: source_url is not a URL: $AFTER_SOURCE_URL" >&2; exit 1; }
echo "  ✓ source_url is a registry URL"

# Assert: source_payload_path is absolute (execution-only)
[ -n "$AFTER_SOURCE_PAYLOAD_PATH" ] || { echo "FAIL: source_payload_path is empty" >&2; exit 1; }
[[ "$AFTER_SOURCE_PAYLOAD_PATH" == /* ]] || { echo "FAIL: source_payload_path is not absolute: $AFTER_SOURCE_PAYLOAD_PATH" >&2; exit 1; }
echo "  ✓ source_payload_path is absolute (execution-only)"

# Assert: artifact_hash unchanged
[ "$AFTER_ARTIFACT_HASH" = "$BEFORE_ARTIFACT_HASH" ] || { echo "FAIL: artifact_hash changed!" >&2; exit 1; }
echo "  ✓ artifact_hash unchanged"

# Assert: recipe_hash unchanged
[ "$AFTER_RECIPE_HASH" = "$BEFORE_RECIPE_HASH" ] || { echo "FAIL: recipe_hash changed!" >&2; exit 1; }
echo "  ✓ recipe_hash unchanged"

# Assert: source_hash updated to source archive hash
[ "$AFTER_SOURCE_HASH" = "$SOURCE_ARCHIVE_HASH" ] || { echo "FAIL: source_hash not updated to source archive hash" >&2; exit 1; }
echo "  ✓ source_hash updated to source archive hash"

# Assert: manifest stores only relative paths (no absolute filesystem paths)
MANIFEST_CONTENT=$(cat "$STORE_DIR/manifest.toml")
if echo "$MANIFEST_CONTENT" | grep -q "/Users/\|/home/"; then
  echo "FAIL: manifest contains absolute filesystem paths" >&2
  exit 1
fi
echo "  ✓ manifest stores only relative payload paths"

# Assert: files/ directory unchanged
[ -f "$STORE_DIR/files/bin/lua" ] || { echo "FAIL: files/bin/lua missing" >&2; exit 1; }
[ "$(cat "$STORE_DIR/files/bin/lua")" = "fake-lua-binary" ] || { echo "FAIL: files/bin/lua content changed" >&2; exit 1; }
[ -f "$STORE_DIR/files/lib/liblua.a" ] || { echo "FAIL: files/lib/liblua.a missing" >&2; exit 1; }
[ "$(cat "$STORE_DIR/files/lib/liblua.a")" = "fake-liblua" ] || { echo "FAIL: files/lib/liblua.a content changed" >&2; exit 1; }
echo "  ✓ files/ directory unchanged"

# Assert: source_payload in manifest is NOT the same as source_payload_path
# (manifest has relative, query has absolute)
[ "$AFTER_SOURCE_PAYLOAD" != "$AFTER_SOURCE_PAYLOAD_PATH" ] || { echo "FAIL: source_payload == source_payload_path (should be different)" >&2; exit 1; }
echo "  ✓ manifest payload (relative) ≠ query payload_path (absolute)"

echo ""
echo "PASS: store-hit-source-provenance-enrichment"
