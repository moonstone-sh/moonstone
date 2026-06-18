local native = require("{{module_name}}_native")

local M = {}

function M.run(args)
  local who = args and args[1] or "Moonstone"

  print(native.hello_from_zig(who))

  local reply = native.call_lua(function(message)
    print("Lua callback got: " .. message)
    return "ack from Lua"
  end)
  print("Zig received callback reply: " .. tostring(reply))

  local state = native.new_state(40)
  native.increment(state)
  native.increment(state)
  print("Shared state count: " .. native.count(state))
end

return M
