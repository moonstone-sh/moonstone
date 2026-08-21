local ansicolors = require("ansicolors")
local argparse = require("argparse")
local dkjson = require("dkjson")
local fun = require("fun")
local inspect = require("inspect")
local lfs = require("lfs")
local lpeg = require("lpeg")
local path = require("pl.path")
local socket = require("socket")

local parser = argparse("rocks-parallel-demo")
parser:flag("--json", "print the resolved capability summary as JSON")
local options = parser:parse()

local words = lpeg.Ct(lpeg.C(lpeg.P("moonstone")) * (lpeg.P(" ") * lpeg.C(lpeg.P("rocks")))^-1):match("moonstone rocks")
local summary = {
    cwd = lfs.currentdir(),
    joined_path = path.join("rocks", "parallel", "demo"),
    socket_version = socket._VERSION,
    words = words,
    numbers = fun.totable(fun.map(function(value) return value * value end, fun.range(1, 5))),
}

if options.json then
    print(dkjson.encode(summary, { indent = true }))
else
    print(ansicolors("%{green}Moonstone resolved and projected the demo rocks.%{reset}"))
    print(inspect(summary))
end
