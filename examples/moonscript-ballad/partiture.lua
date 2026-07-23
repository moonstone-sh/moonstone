local ballad = require("ballad")

return ballad.partiture(function(p)
	local moonstone = p:use(ballad.plugins.moonstone)
	local layout = p:use(ballad.plugins.layout)

	local project = moonstone.project({
		root = ".",
	})

	local assets = moonstone:run("build", {
		inputs = { "./src/*.moon" },
		outputs = { "./build/src" },
	})

	local app = layout.exec(project, {
		entry = "build/src/main.lua",
		bundle_runtime = true,
		include = { "build/src/**" },
		lua_paths = { "build/src", "lua", "src" },
		depends_on = assets,
	})

	p.sink.directory(app, {
		out = "./dist",
	})
end)
