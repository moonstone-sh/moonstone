local ballad = require("ballad")

return ballad.partiture(function(p)
	local moonstone = p:use(ballad.plugins.moonstone)
	local layout = p:use(ballad.plugins.layout)

	local project = moonstone.project({
		root = ".",
	})

	local assets = moonstone:run("build", {
		inputs = { "./src/*.tl", "./tlconfig.lua" },
		outputs = { "./dist" },
	})

	p.sink.none(assets)

	local app = layout.exec(project, {
		name = "teal-example",
		bin = "teal-example",
		entry = "main.lua",
	})

	p.sink.directory(app, {
		out = "./dist",
	})
end)
