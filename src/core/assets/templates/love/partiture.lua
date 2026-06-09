local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use("moonstone")
  local love = p:use("love")
  local emit = p:use("emit")

  local project = moonstone.project({ root = "." })
  local app = love.layout(project, {
    main = "main.lua",
    conf = "conf.lua",
    include = {
      "main.lua",
      "conf.lua",
      "src/**",
      "assets/**",
    },
  })

  emit.directory(app, { out = "dist/love-root" })
  love.pack(app, { out = "dist/" .. project.name .. ".love" })
end)
