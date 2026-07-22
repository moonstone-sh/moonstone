local CLI = require("cli")

local args = { ... } as {string}
local opts = CLI.parse(args)
CLI.run(opts)
