local config = require("{{module_name}}.config")

local M = {}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", {}, config.defaults, opts or {})
  return M.config
end

return M
