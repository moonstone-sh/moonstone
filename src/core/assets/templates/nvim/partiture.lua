local ballad = require("ballad")

-- Set the Neovim target version for package metadata.
-- Examples: "0.11", "0.12.2", "0.13.0".
local nvim_version = os.getenv("NVIM_VERSION") or "{{nvim_version}}"
local nvim_runtime = "nvim@" .. nvim_version

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local nvim = p:use(ballad.plugins.nvim)

  local project = moonstone.project({ root = "." })

  local plugin = nvim.layout(project, {
    module = "{{module_name}}",
    out = ".ballad/tmp/nvim-layout",
    runtime = nvim_runtime,
    lua_api = "5.1",
    lua_abi = "5.1",
    dependencies = ballad.plugins.nvim.extern({
      -- Examples:
      -- "plenary", -- built-in suggestion: nvim-lua/plenary.nvim as external
      -- telescope = { package = "nvim-telescope/telescope.nvim", optional = true },
    }),
  })

  local registry_artifact = moonstone.registry.package(plugin, {
    name = project.registry_name or project.name,
    version = project.version,
    target = "any",
    runtime = nvim_runtime,
    lua_api = "5.1",
    lua_abi = "5.1",
    description = project.description,
  })

  p.sink.directory(plugin, {
    out = "dist/nvim-plugin",
    file_graph = true,
  })
  p.sink.artifact(registry_artifact, {
    out = "dist/nvim-plugin/registry-artifact",
  })
end)
