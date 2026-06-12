local ballad = require("ballad")

return ballad.partiture(function(p)
	local moonstone = p:use(ballad.plugins.moonstone)
	local love = p:use(ballad.plugins.love)

	local project = moonstone.project({ root = "." })
	local app = love.layout(project, {
		main = "main.lua",
		conf = "conf.lua",
		include = { "main.lua", "conf.lua", "src/**", "assets/**" },
	})

	p.sink.directory(app, { out = "dist/love-root", file_graph = true })
	p.sink.artifact(love.pack(app, { name = project.name }), {
		out = "dist/" .. project.name .. ".love",
	})
end)
