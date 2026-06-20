local input = arg[1] or "src/main.lua"
local output = arg[2] or ".meteorite/graph/current"
local mode = arg[3] or "hybrid_dev"
local build_args = arg[4] or ("-Dmode=" .. mode .. " -Dbackend=std_http -Dhybrid-profile=optimized -Drouter-dispatch=param_matchers")
local server = arg[5] or "dist/server"
local state_dir = ".meteorite/dev"
local pid_file = state_dir .. "/server.pid"
local log_file = state_dir .. "/server.log"
local port = "8080"

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

local function capture(command)
  local pipe = io.popen(command, "r")
  if not pipe then return "" end
  local data = pipe:read("*a") or ""
  pipe:close()
  return data
end

local function mkdir_p(path)
  os.execute("mkdir -p " .. string.format("%q", path))
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

local function processes_on_port()
  return capture("lsof -i :" .. port .. " 2>/dev/null | awk '/LISTEN/ {print $2}' | sort -u")
end

local function stop_server()
  -- Kill by recorded PID first.
  local pid = read_file(pid_file)
  if pid then
    pid = pid:match("%d+")
    if pid then os.execute("kill " .. pid .. " >/dev/null 2>&1 || true") end
  end
  -- Also kill anything still listening on the dev port so restarts do not
  -- pile up when the recorded PID is stale.
  for stale_pid in processes_on_port():gmatch("%d+") do
    os.execute("kill " .. stale_pid .. " >/dev/null 2>&1 || true")
  end
  -- Wait until the port is actually free.
  for _ = 1, 30 do
    if processes_on_port():match("%d+") then
      os.execute("sleep 0.1")
    else
      break
    end
  end
end

local function start_server()
  stop_server()
  -- TODO: implement a more robust child-process supervisor (e.g. luaposix
  -- signal handling) so SIGINT/SIGTERM reliably reaps the server instead of
  -- relying on a background guard shell.
  local guard_script = state_dir .. "/guard.sh"
  local guard_body = table.concat({
    "#!/bin/sh",
    "set -eu",
    "trap 'kill $SERVER_PID 2>/dev/null || true' EXIT INT TERM",
    shell_quote(server) .. " >" .. shell_quote(log_file) .. " 2>&1 & SERVER_PID=$!",
    "echo $SERVER_PID > " .. shell_quote(pid_file),
    "while kill -0 $SERVER_PID 2>/dev/null; do sleep 1; done",
  }, "\n")
  write_file(guard_script, guard_body)
  os.execute("chmod +x " .. shell_quote(guard_script))
  -- nohup detaches the guard from dev.lua's controlling terminal so the
  -- dev loop can keep watching files. The guard still lives in the same
  -- process group, so a terminal signal usually reaches it.
  os.execute("nohup " .. shell_quote(guard_script) .. " >/dev/null 2>&1 &")
  -- Wait for the server to actually listen before declaring it started.
  local server_pid = nil
  for _ = 1, 100 do
    local pids = processes_on_port()
    server_pid = pids:match("%d+")
    if server_pid then break end
    os.execute("sleep 0.1")
  end
  if server_pid then
    write_file(pid_file, server_pid .. "\n")
    io.stderr:write("Meteorite dev server: http://127.0.0.1:" .. port .. " pid=" .. server_pid .. " log=" .. log_file .. "\n")
  else
    io.stderr:write("Meteorite dev server: failed to start on port " .. port .. "; log follows:\n")
    local log = read_file(log_file) or ""
    io.stderr:write(log)
    io.stderr:write("\n")
  end
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
  local only_plugins = true
  for _, change in ipairs(changes) do
    if change.kind ~= "lua_chunk" and change.kind ~= "lua_chunks" and change.kind ~= "plugin" and change.kind ~= "plugins" then
      only_lua_chunks = false
    end
    if change.kind ~= "plugin" and change.kind ~= "plugins" then
      only_plugins = false
    end
  end
  if only_lua_chunks then return "reload", "Lua/plugin chunk changes only" end
  return "rebuild", "graph/native-affecting partitions changed"
end

local function reload_lua()
  return run("curl -fsS -X POST http://127.0.0.1:" .. port .. "/__meteorite/reload-lua >/dev/null")
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
  if not previous then return false end
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
    local force_build = not file_exists(server) or changed_native_or_build(last, current)
    last = current
    io.stderr:write("\nMeteorite dev: change detected; regenerating graph...\n")
    if graph() then
      local changes = parse_partition_changes()
      io.stderr:write("Meteorite dev: partitions " .. summarize_changes(changes) .. "\n")
      local action, reason = classify_changes(changes, force_build)
      io.stderr:write("Meteorite dev: action=" .. action .. " reason=" .. reason .. "\n")
      if action == "none" then
        if not processes_on_port():match("%d+") then start_server() end
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
