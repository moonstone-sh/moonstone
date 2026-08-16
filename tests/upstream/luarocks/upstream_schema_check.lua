local upstream_root = arg[1]
local fixture = arg[2]

if not upstream_root or not fixture then
   io.stderr:write("usage: upstream_schema_check.lua <luarocks-root> <rockspec>\n")
   os.exit(64)
end

package.path = table.concat({
   upstream_root .. "/src/?.lua",
   upstream_root .. "/src/?/init.lua",
   upstream_root .. "/vendor/?.lua",
   upstream_root .. "/vendor/?/init.lua",
   package.path,
}, ";")

local persist = require("luarocks.core.persist")
local schema = require("luarocks.type.rockspec")

local rockspec, globals_or_error = persist.load_into_table(fixture)
if not rockspec then
   io.stderr:write("syntax: " .. tostring(globals_or_error) .. "\n")
   os.exit(2)
end

local ok, err = schema.check(rockspec, globals_or_error)
if not ok then
   io.stderr:write("schema: " .. tostring(err) .. "\n")
   os.exit(3)
end
