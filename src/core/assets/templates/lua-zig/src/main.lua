local source = debug.getinfo(1, "S").source:sub(2)
local src_dir = source:match("^(.*[/\\])") or "./src/"
package.path = src_dir .. "?.lua;" .. src_dir .. "?/init.lua;" .. package.path

local app = require("app")

app.run(arg)
