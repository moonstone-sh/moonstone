local m = require("meteorite")

---@type MeteoriteApp
local app = m.app({ name = "{{name}}" })

app:get("/", function(c)
  return c:text("hello from {{name}}")
end)

app:get("/health", function(c)
  return c:json({ ok = true })
end)

return app
