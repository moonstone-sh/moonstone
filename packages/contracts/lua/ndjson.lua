---@meta
-- Moonstone NDJSON LuaCATS Type Definitions
-- This file provides autocompletion and type information for editors using lua-language-server.

---@alias MessageKind
---| '"START"'
---| '"PROGRESS"'
---| '"STATUS"'
---| '"ERROR"'
---| '"WARN"'
---| '"RESULT"'
---| '"PROMPT"'
---| '"INFO"'
---| '"DUMP"'

---@class EnvelopeMetadata
---@field command string The command name (e.g. "sync", "add")
---@field pid integer Process ID of the invoking moon instance
---@field version string Moonstone CLI version

---@class EnvelopeError
---@field code string Unique error identifier (e.g. "error.hash-mismatch")
---@field message string Human-readable error description

---@class ArtifactData
---@field version string|nil Resolved semantic version
---@field state string|nil Lifecycle state (e.g. "done", "failed")
---@field materializer string|nil Materializer kind ("prebuilt", "command", etc.)
---@field bytes_downloaded integer|nil Bytes downloaded so far
---@field bytes_total integer|nil Expected total bytes
---@field bytes_per_second number|nil Current throughput speed
---@field artifact_hash string|nil BLAKE3 hash of the artifact
---@field elapsed_ms integer|nil Time spent processing
---@field error string|nil Error value if state is "failed"
---@field error_detail string|nil Execution output or logs from failure
---@field registry string|nil Origin registry name
---@field target string|nil Target triple
---@field cache_hit boolean|nil True if artifact was found in local store
---@field warn string|nil Warning message if present
---@field resolved_kind string|nil Package kind override
---@field override string|nil
---@field manifest_table string|nil Section inside moonstone.toml
---@field symlink string|nil Absolute path of projected symlink
---@field old_version string|nil For update events
---@field new_version string|nil For update events
---@field old_constraint string|nil For upgrade events
---@field new_constraint string|nil For upgrade events
---@field path string|nil For link/unlink/install directories
---@field recreated boolean|nil True if doctor recreated files

---@class MessageEnvelope
---@field kind MessageKind The type of NDJSON event
---@field timestamp string ISO-8601 timestamp
---@field seq integer Monotonic sequence number
---@field about string Subject of the event
---@field value string Short status reading or progress percent
---@field data table<string, ArtifactData>|table Payloads (command-specific or artifact map)
---@field terminator boolean True if this is the final message of the stream
---@field meta EnvelopeMetadata|nil Invocation metadata
---@field error EnvelopeError|nil Present if final status is aborted

-- ── Command Specific Data Payloads (Casting targets) ────────────────

---@class AddStartData
---@field packages string[] List of packages requested for installation
---@field dev boolean True if added to dev dependencies

---@class AddResultData
---@field added string[] Packages successfully added
---@field failed string[] Packages that failed to resolve/install
---@field env_regenerated boolean True if .moonstone/env/ was re-linked

---@class RemoveResultData
---@field removed string[] Packages removed
---@field env_regenerated boolean

---@class SyncStartData
---@field locked boolean True if running in locked verification mode
---@field offline boolean True if running in offline mode

---@class SyncResultData
---@field artifacts_ok integer Number of successfully materialized artifacts
---@field artifacts_failed integer Number of failed materializations
---@field duration_ms integer Total execution duration

---@class StoreGcResultData
---@field deleted integer Number of unused artifacts purged
---@field freed_bytes integer Total bytes reclaimed

---@class DoctorResultData
---@field issues integer Count of critical issues found
---@field warnings integer Count of warnings found
---@field checks_passed integer
---@field checks_failed integer
