local ballad = require("ballad")

return ballad.partiture(function(p)
	local moonstone = p:use(ballad.plugins.moonstone)
	local layout = p:use(ballad.plugins.layout)

	local project = moonstone.project({
		root = ".",
	})

	local assets = moonstone:run("build", {
		inputs = { "./src/*.tl", "./tlconfig.lua" },
		outputs = { "./build" },
	})

	local app = layout.exec(project, {
		name = "teal-example",
		bin = "teal-example",
		entry = "build/main.lua",
		bundle_runtime = true,
		include = { "build/**" },
		lua_paths = { "build", "lua", "src" },
		depends_on = assets,
	})

	p.sink.directory(app, {
		out = "./dist",
	})
end)
