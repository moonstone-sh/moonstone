---@meta
-- Generated from packages/contracts/schema by scripts/generate-lua-annotations.mjs.
-- Do not hand-edit; run `bun run generate:lua` from packages/contracts.

---@class MoonstoneLockExportV1
---@field contract '"moonstone:lock:v1"'
---@field storage_revision MoonstoneLockStorageRevision
---@field lockfile_version integer
---@field packages MoonstoneLockedPackageV1[]
---@field profiles MoonstoneLockProfileV1[]

---@alias MoonstoneLockStorageRevision string

---@class MoonstoneLockedPackageV1
---@field name string
---@field version string
---@field kind string
---@field resolver string
---@field registry string
---@field artifact_hash string
---@field source_hash string
---@field recipe_hash string
---@field runtime string
---@field lua_abi string
---@field target string
---@field replay_mode string
---@field reproducible boolean

---@class MoonstoneLockProfileV1
---@field id string
---@field target string
---@field runtime string
---@field lua_abi string|nil
---@field package_count integer
---@field edge_count integer
