local M = {}

function M.host()
  assert(type(vim) == "table", "nvim_host_example must run inside Neovim")
  return "neovim"
end

function M.plenary_path()
  local Path = require("plenary.path")
  return Path:new(vim.fn.stdpath("data")):absolute()
end

return M
