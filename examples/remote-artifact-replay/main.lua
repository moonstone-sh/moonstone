local lpeg = require("lpeg")
local p = lpeg.P("hello")
print("LPeg pattern match result:", p:match("hello world"))
