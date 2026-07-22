local ballad = require("ballad")

return ballad.partiture(function(p)
	local moonstone = p:use(ballad.plugins.moonstone)
	local layout = p:use(ballad.plugins.layout)

	local project = moonstone.project({
		root = ".",
	})

	local assets = moonstone:run("build", {
		inputs = { "./src/*.moon" },
		outputs = { "./dist/src" },
	})

	p.sink.none(assets)

	local app = layout.exec(project, {
		entry = "src/main.lua",
		bundle_runtime = true,
	})

	p.sink.directory(app, {
		out = "./dist",
	})
end)
