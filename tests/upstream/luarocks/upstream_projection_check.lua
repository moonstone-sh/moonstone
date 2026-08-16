local upstream_root = arg[1]
local fixture = arg[2]
local work_dir = arg[3]

if not upstream_root or not fixture or not work_dir then
   io.stderr:write("usage: upstream_projection_check.lua <luarocks-root> <rockspec> <work-dir>\n")
   os.exit(64)
end

package.path = table.concat({
   upstream_root .. "/src/?.lua",
   upstream_root .. "/src/?/init.lua",
   upstream_root .. "/vendor/?.lua",
   upstream_root .. "/vendor/?/init.lua",
   package.path,
}, ";")

local cfg = require("luarocks.core.cfg")
assert(cfg.init())
cfg.root_dir = work_dir

local persist = require("luarocks.core.persist")
local rockspecs = require("luarocks.rockspecs")
local json = require("dkjson")

local rockspec, globals_or_error = persist.load_into_table(fixture)
if not rockspec then
   io.stderr:write("syntax: " .. tostring(globals_or_error) .. "\n")
   os.exit(2)
end

local projected, err = rockspecs.from_persisted_table(fixture, rockspec, globals_or_error)
if not projected then
   io.stderr:write("projection: " .. tostring(err) .. "\n")
   os.exit(3)
end

local function declaration_array(value)
   local result = {}
   if type(value) ~= "table" then
      return result
   end
   for index = 1, #value do
      result[#result + 1] = value[index]
   end
   return result
end

local function source_projection(source)
   local result = {}
   for _, field in ipairs({ "url", "md5", "file", "dir", "tag", "branch", "module", "cvs_tag", "cvs_module" }) do
      if field ~= "file" and source[field] ~= nil then
         result[field] = source[field]
      end
   end
   return result
end

local function resolver_build_projection(projected)
   local build = projected.build
   if build == nil and projected.format_is_at_least and projected:format_is_at_least("3.0") then
      -- LuaRocks' build dispatcher supplies this default for format 3.0+
      -- rockspecs after persisted-table loading. The parity contract compares
      -- resolver intent, not just storage fields.
      build = { type = "builtin" }
   elseif type(build) == "table" and build.type == nil and projected.format_is_at_least and projected:format_is_at_least("3.0") then
      build.type = "builtin"
   end
   return build
end

local encoded, encode_error = json.encode({
   source = source_projection(projected.source),
   dependencies = declaration_array(projected.dependencies),
   build_dependencies = declaration_array(projected.build_dependencies),
   test_dependencies = declaration_array(projected.test_dependencies),
   external_dependencies = projected.external_dependencies,
   build = resolver_build_projection(projected),
   hooks = projected.hooks,
   test = projected.test,
})
assert(encoded, encode_error)
io.write(encoded)
