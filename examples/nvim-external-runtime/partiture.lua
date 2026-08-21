  local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local nvim = p:use(ballad.plugins.nvim)

  local project = moonstone.project({ root = "." })
  local plugin = nvim.layout(project, {
    module = "nvim_host_example",
    out = ".ballad/tmp/nvim-layout",
    runtime = "nvim@0.12.4",
    lua_api = "5.1",
    lua_abi = "5.1",
    dependencies = ballad.plugins.nvim.extern({
      "plenary",
    }),
  })

  local artifact = moonstone.registry.package(plugin, {
    name = project.name,
    version = project.version,
    target = "any",
    runtime = "nvim@0.12.4",
    lua_api = "5.1",
    lua_abi = "5.1",
    description = project.description,
  })

  p.sink.directory(plugin, { out = "dist/nvim-plugin", file_graph = true })
  p.sink.artifact(artifact, { out = "dist/nvim-plugin/registry-artifact" })
end)
