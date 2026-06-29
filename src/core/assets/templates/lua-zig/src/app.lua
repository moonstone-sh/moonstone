local zig = require("{{module_name}}_zig")

local M = {}

function M.run(args)
  local who = args and args[1] or "Moonstone"

  print(zig.hello_from_zig(who))

  local reply = zig.call_lua(function(message)
    print("Lua callback got: " .. message)
    return "ack from Lua"
  end)
  print("Zig received callback reply: " .. tostring(reply))

  local state = zig.new_state(40)
  zig.increment(state)
  zig.increment(state)
  print("Shared state count: " .. zig.count(state))
end

return M
