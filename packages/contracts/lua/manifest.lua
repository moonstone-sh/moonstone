---@meta
-- Generated from packages/contracts/schema by scripts/generate-lua-annotations.mjs.
-- Do not hand-edit; run `bun run generate:lua` from packages/contracts.

---@class MoonstoneManifestExportV1
---@field contract '"moonstone:manifest:v1"'
---@field storage_revision MoonstoneStorageRevision
---@field manifest MoonstoneManifestV1

---@alias MoonstoneStorageRevision string

---@class MoonstoneScriptV1
---@field name string
---@field command string

---@class MoonstoneManifestTidyV1
---@field scripts '"lexicographic"'|'"preserve"'
---@field on_script_mutation boolean

---@class MoonstoneManifestV1
---@field manifest_version integer
---@field project table
---@field runtime table
---@field origin table|nil
---@field tidy MoonstoneManifestTidyV1
---@field dependencies table[]
---@field scripts MoonstoneScriptV1[]
---@field registries table[]
---@field orbits table[]

---@class MoonstoneManifestEditResultV1
---@field contract '"moonstone:manifest-edit-result:v1"'
---@field storage_revision string
---@field applied integer
---@field storage_mode '"source_preserving"'|'"canonicalized"'
