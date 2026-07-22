local CLI = require("cli")

local args = { ... }
local opts = CLI.parse(args)
CLI.run(opts)
