local input = arg[1] or "src/main.lua"
local output = arg[2] or ".meteorite/graph/current"
local mode = arg[3] or "hybrid_dev"
local build_args = arg[4] or ("-Dmode=" .. mode .. " -Dbackend=std_http -Dhybrid-profile=optimized -Drouter-dispatch=param_matchers")
local server = arg[5] or "dist/server"
local state_dir = ".meteorite/dev"
local pid_file = state_dir .. "/server.pid"
local log_file = state_dir .. "/server.log"
local guard_script = "scripts/guard.sh"
local dev_port = os.getenv("METEORITE_DEV_PORT") or "8080"

local function path_exists(path)
  local file = io.open(path, "rb")
  if file then file:close(); return true end
  return false
end

local lua_bin = os.getenv("METEORITE_LUA") or (path_exists(".moonstone/env/bin/lua") and ".moonstone/env/bin/lua" or "lua")
local meteorite_root = os.getenv("METEORITE_ROOT") or ".moonstone/env/libexec/meteorite"

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function run(command)
  io.stderr:write("$ " .. command .. "\n")
  local ok, _, code = os.execute(command)
  return ok == true or ok == 0 or code == 0
end

local function quiet_run(command)
  local ok, _, code = os.execute(command)
  return ok == true or ok == 0 or code == 0
end

local function capture(command)
  local pipe = io.popen(command, "r")
  if not pipe then return "" end
  local data = pipe:read("*a") or ""
  pipe:close()
  return data
end

local function mkdir_p(path)
  os.execute("mkdir -p " .. shell_quote(path))
end

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local data = file:read("*a")
  file:close()
  return data
end

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  if not file then error("cannot write " .. path .. ": " .. tostring(err)) end
  file:write(content)
  file:close()
end

local function guard(command)
  if not path_exists(guard_script) then return false end
  local env = table.concat({
    "METEORITE_DEV_STATE_DIR=" .. shell_quote(state_dir),
    "METEORITE_DEV_PID_FILE=" .. shell_quote(pid_file),
    "METEORITE_DEV_PORT=" .. shell_quote(dev_port),
    "METEORITE_DEV_SERVER=" .. shell_quote(server),
  }, " ")
  return run(env .. " sh " .. shell_quote(guard_script) .. " " .. shell_quote(command))
end

local function pid_running(pid)
  return pid ~= nil and quiet_run("kill -0 " .. tostring(pid) .. " >/dev/null 2>&1")
end

local function current_server_pid()
  local pid = read_file(pid_file)
  return pid and pid:match("%d+") or nil
end

local function server_running()
  return pid_running(current_server_pid())
end

local function stop_server()
  if guard("cleanup") then return end
  local pid = current_server_pid()
  if pid then
    os.execute("kill " .. pid .. " >/dev/null 2>&1 || true")
    os.remove(pid_file)
  end
end

local function start_server()
  if not guard("assert-free") then stop_server() end
  local command = shell_quote(server) .. " >" .. shell_quote(log_file) .. " 2>&1 & echo $!"
  local pid = capture(command):match("%d+")
  if pid then write_file(pid_file, pid .. "\n") end
  os.execute("sleep 0.1")
  if pid and not pid_running(pid) then
    io.stderr:write("Meteorite dev server failed to stay running; see " .. log_file .. "\n")
  end
  io.stderr:write("Meteorite dev server: http://127.0.0.1:" .. dev_port .. " pid=" .. tostring(pid or "?") .. " log=" .. log_file .. "\n")
end

local function source_fingerprint()
  local command = table.concat({
    "{ find src native -type f 2>/dev/null; test -f build.zig && echo build.zig; test -f moonstone.toml && echo moonstone.toml; }",
    "| sort",
    "| while IFS= read -r f; do stat -f '%m %z %N' \"$f\" 2>/dev/null || stat -c '%Y %s %n' \"$f\" 2>/dev/null; done"
  }, " ")
  return capture(command)
end

local function parse_partition_changes()
  local text = read_file(output .. "/partition-changes.json") or "[]"
  local changes = {}
  local current = {}
  for line in text:gmatch("[^\n]+") do
    local status = line:match('"status"%s*:%s*"([^"]+)"')
    if status then current = { status = status } end
    local kind = line:match('"kind"%s*:%s*"([^"]+)"')
    if kind then current.kind = kind end
    local id = line:match('"id"%s*:%s*"([^"]+)"')
    if id then
      current.id = id
      changes[#changes + 1] = current
      current = {}
    end
  end
  return changes
end

local function summarize_changes(changes)
  if #changes == 0 then return "none" end
  local counts = {}
  for _, change in ipairs(changes) do counts[change.kind] = (counts[change.kind] or 0) + 1 end
  local keys = {}
  for kind, _ in pairs(counts) do keys[#keys + 1] = kind end
  table.sort(keys)
  local parts = {}
  for _, kind in ipairs(keys) do parts[#parts + 1] = kind .. "=" .. tostring(counts[kind]) end
  return table.concat(parts, ", ")
end

local function classify_changes(changes, force_build)
  if force_build then return "rebuild", "native/build input changed" end
  if #changes == 0 then return "none", "no graph partition changes" end
  local only_lua_chunks = true
  for _, change in ipairs(changes) do
    if change.kind ~= "lua_chunk" and change.kind ~= "lua_chunks" and change.kind ~= "plugin" and change.kind ~= "plugins" then
      only_lua_chunks = false
      break
    end
  end
  if only_lua_chunks then return "reload", "Lua/plugin chunk changes only" end
  return "rebuild", "graph/native-affecting partitions changed"
end

local function reload_lua()
  return run("curl -fsS -X POST http://127.0.0.1:" .. dev_port .. "/__meteorite/reload-lua >/dev/null")
end

local function graph()
  local graph_command = table.concat({ shell_quote(lua_bin), shell_quote(meteorite_root .. "/src/meteorite/cli.lua"), "graph", shell_quote(input), shell_quote(output), shell_quote(mode) }, " ")
  return run(graph_command)
end

local function build()
  local build_command = "zig build install-server " .. build_args .. " -- " .. shell_quote(server)
  return run(build_command)
end

local function file_exists(path)
  local file = io.open(path, "rb")
  if file then file:close(); return true end
  return false
end

local function changed_native_or_build(previous, current)
  if not previous then return true end
  local function filter(text)
    local out = {}
    for line in tostring(text):gmatch("[^\n]+") do
      if line:match(" native/") or line:match(" build%.zig$") or line:match(" moonstone%.toml$") then out[#out + 1] = line end
    end
    return table.concat(out, "\n")
  end
  return filter(previous) ~= filter(current)
end

mkdir_p(state_dir)
local running = true
local function handle_signal()
  running = false
  stop_server()
  os.exit(0)
end

io.stderr:write("Meteorite dev: watching src/, native/, build.zig, moonstone.toml\n")
io.stderr:write("Meteorite dev: mode=" .. mode .. " build_args=" .. build_args .. "\n")
io.stderr:write("Press Ctrl-C to stop.\n")

local last = nil
while running do
  local current = source_fingerprint()
  if current ~= last then
    local force_build = changed_native_or_build(last, current) or not file_exists(server)
    last = current
    io.stderr:write("\nMeteorite dev: change detected; regenerating graph...\n")
    if graph() then
      local changes = parse_partition_changes()
      io.stderr:write("Meteorite dev: partitions " .. summarize_changes(changes) .. "\n")
      local action, reason = classify_changes(changes, force_build)
      io.stderr:write("Meteorite dev: action=" .. action .. " reason=" .. reason .. "\n")
      if action == "none" then
        if not server_running() then start_server() end
      elseif action == "reload" then
        if reload_lua() then
          io.stderr:write("Meteorite dev: Lua handlers and plugins reloaded in-process.\n")
        else
          io.stderr:write("Meteorite dev: Lua reload failed; restarting server.\n")
          start_server()
        end
      elseif build() then
        start_server()
      else
        io.stderr:write("Meteorite dev: build failed; keeping previous server state.\n")
      end
    else
      io.stderr:write("Meteorite dev: graph failed; keeping previous server state.\n")
    end
  end
  os.execute("sleep 1")
end

handle_signal()
