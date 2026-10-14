-- moonstone.variants: flavor-tagged module files (`lexer@lua54.lua`).
--
-- Written into every project environment by `moon sync`. This is the Lua
-- twin of `src/core/platform/flavor.zig`: the linker uses the Zig version to
-- project dependencies, while this one serves the runtime searcher (for a
-- project's own sources) and build tools such as Quaver that specialize for
-- a flavor other than the host's. Keep the two in step.
--
-- `parse`, `match`, `select` and `suffixes` are pure and run anywhere;
-- `resolve` and `install` need the standard `io` and `package` libraries
-- (Lua 5.1-5.5, LuaJIT).

local M = {}

M.language_tags = { "lua51", "lua52", "lua53", "lua54", "lua55", "luajit", "luau" }
M.os_tags = { "linux", "macos", "windows", "freebsd" }
M.arch_tags = { "x86_64", "aarch64", "riscv64" }

local LANGUAGE, OS, ARCH = 1, 2, 3
local dimension_of = {}
for _, tag in ipairs(M.language_tags) do dimension_of[tag] = LANGUAGE end
for _, tag in ipairs(M.os_tags) do dimension_of[tag] = OS end
for _, tag in ipairs(M.arch_tags) do dimension_of[tag] = ARCH end

local function split_tags(tags)
  local out = {}
  for tag in string.gmatch(tags, "@([^@]*)") do out[#out + 1] = tag end
  return out
end

--- Split a file name into its variant parts.
--- Returns nil for an ordinary file, `false, message` for a malformed one.
---@param file_name string
---@return {stem: string, ext: string, tags: string[]}|nil|false variant
---@return string? message
function M.parse(file_name)
  local base, ext = string.match(file_name, "^(.+)(%.[^.@/\\]+)$")
  if not base then return nil end
  local stem, tags = string.match(base, "^([^@]+)(@.+)$")
  if not stem then return nil end
  local list = split_tags(tags)
  for _, tag in ipairs(list) do
    if not dimension_of[tag] then return nil end
  end
  local previous = 0
  for _, tag in ipairs(list) do
    local dimension = dimension_of[tag]
    if dimension <= previous then
      return false, file_name .. ": tags must be in language, os, arch order, at most one each"
    end
    previous = dimension
  end
  return { stem = stem, ext = ext, tags = list }
end

local function language_match(tag, flavor)
  if tag == "luajit" then return flavor.family == "luajit" and 2 or nil end
  if tag == "luau" then return flavor.family == "luau" and 2 or nil end
  local level = tonumber(string.sub(tag, 4))
  if level ~= flavor.level then return nil end
  if flavor.family == "lua" then return 2 end
  -- LuaJIT runs Lua 5.1 code; Luau's syntax and library differ too much.
  if flavor.family == "luajit" then return 1 end
  return nil
end

--- How specifically a parsed variant applies to a flavor, or nil.
---@return {[1]: integer, [2]: integer, [3]: integer}|nil
function M.match(variant, flavor)
  local spec = { 0, 0, 0 }
  for _, tag in ipairs(variant.tags) do
    local dimension = dimension_of[tag]
    if dimension == LANGUAGE then
      local score = language_match(tag, flavor)
      if not score then return nil end
      spec[LANGUAGE] = score
    elseif dimension == OS then
      if tag ~= flavor.os then return nil end
      spec[OS] = 1
    else
      if tag ~= flavor.arch then return nil end
      spec[ARCH] = 1
    end
  end
  return spec
end

local function at_least(a, b)
  return a[1] >= b[1] and a[2] >= b[2] and a[3] >= b[3]
end

local function equal(a, b)
  return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

--- Choose among a module's files. `candidates` are parsed variants;
--- `has_base` says whether the untagged file exists.
--- Returns "variant", index | "base" | "none" | "ambiguous", i, j.
function M.select(candidates, has_base, flavor)
  local best, best_spec, have_best = nil, { 0, 0, 0 }, has_base
  for index, candidate in ipairs(candidates) do
    local spec = M.match(candidate, flavor)
    if spec and (not have_best or at_least(spec, best_spec)) then
      best, best_spec, have_best = index, spec, true
    end
  end
  if not have_best then return "none" end
  for index, candidate in ipairs(candidates) do
    if index ~= best then
      local spec = M.match(candidate, flavor)
      if spec and (not at_least(best_spec, spec) or equal(best_spec, spec)) then
        return "ambiguous", index, best
      end
    end
  end
  if best then return "variant", best end
  return "base"
end

--- Every tag suffix that could match `flavor`, in canonical order. The
--- searcher probes these instead of listing directories.
function M.suffixes(flavor)
  local languages = { false }
  if flavor.family == "lua" then
    languages[#languages + 1] = "lua" .. flavor.level
  else
    languages[#languages + 1] = flavor.family
    if flavor.family == "luajit" then languages[#languages + 1] = "lua51" end
  end
  local out = {}
  for _, language in ipairs(languages) do
    for _, os_tag in ipairs({ false, flavor.os }) do
      for _, arch_tag in ipairs({ false, flavor.arch }) do
        local suffix = (language and "@" .. language or "")
          .. (os_tag and "@" .. os_tag or "")
          .. (arch_tag and "@" .. arch_tag or "")
        if suffix ~= "" then out[#out + 1] = suffix end
      end
    end
  end
  return out
end

local function readable(path)
  local file = io.open(path, "rb")
  if file then file:close() return true end
  return false
end

local dirsep = string.sub(package.config, 1, 1)
local pathsep = string.sub(package.config, 3, 3)

--- Find the file `require(name)` should load for `flavor` on `path`.
--- Returns the chosen file (nil when no variant applies; the plain file, if
--- any, is then left to the standard searcher) or raises on ambiguity.
function M.resolve(name, flavor, path)
  path = path or package.path
  local suffixes = M.suffixes(flavor)
  local relative = string.gsub(name, "%.", dirsep)
  for template in string.gmatch(path, "[^" .. pathsep .. "]+") do
    local filename = string.gsub(template, "%?", relative)
    local base, ext = string.match(filename, "^(.+)(%.[^.@/\\]+)$")
    if base then
      local candidates, files = {}, {}
      for _, suffix in ipairs(suffixes) do
        local candidate = base .. suffix .. ext
        if readable(candidate) then
          candidates[#candidates + 1] = { tags = split_tags(suffix) }
          files[#files + 1] = candidate
        end
      end
      local has_base = readable(filename)
      if #candidates > 0 then
        local choice, first, second = M.select(candidates, has_base, flavor)
        if choice == "variant" then return files[first] end
        if choice == "ambiguous" then
          error(string.format("module '%s': %s and %s are equally specific for %s",
            name, files[first], second and files[second] or filename, flavor.id), 0)
        end
        return nil
      end
      if has_base then return nil end
    end
  end
  return nil
end

local installed = false

--- Add a searcher that loads flavor variants of a project's own modules.
--- Dependencies need no searcher: `moon sync` already projected one file per
--- module. Idempotent.
function M.install(flavor)
  if installed then return end
  installed = true
  flavor = flavor or require("moonstone.target")
  local searchers = package.searchers or package.loaders
  table.insert(searchers, 2, function(name)
    local file = M.resolve(name, flavor)
    if not file then return "\n\tno flavor variant for '" .. name .. "'" end
    local loader, message = loadfile(file)
    if not loader then error(message, 0) end
    return loader, file
  end)
end

return M
