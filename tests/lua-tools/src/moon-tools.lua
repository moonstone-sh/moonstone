#!/usr/bin/env lua

local ok_json, json = pcall(require, "dkjson")
if not ok_json then json = nil end
local ok_lfs, lfs = pcall(require, "lfs")
if not ok_lfs then lfs = nil end

local function die(msg)
  io.stderr:write("Error: " .. msg .. "\n")
  os.exit(1)
end

local function script_dir()
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  return source:match("^(.*)/[^/]+$") or "."
end

local ROOT = (function()
  local dir = script_dir()
  local handle = io.popen('cd "' .. dir .. '/../../.." && pwd')
  local out = handle:read("*l")
  handle:close()
  return out
end)()

local function join(...)
  local parts = { ... }
  local out = tostring(parts[1] or "")
  for i = 2, #parts do
    local p = tostring(parts[i])
    if out:sub(-1) == "/" then out = out .. p else out = out .. "/" .. p end
  end
  return out
end

local function q(path)
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

local function exists(path)
  return lfs and lfs.attributes(path) ~= nil or os.execute("test -e " .. q(path)) == true
end

local function is_dir(path)
  return lfs and (lfs.attributes(path, "mode") == "directory") or os.execute("test -d " .. q(path)) == true
end

local function mkdir_p(path)
  local ok = os.execute("mkdir -p " .. q(path))
  if ok ~= true and ok ~= 0 then die("mkdir failed: " .. path) end
end

local function rm_rf(path)
  if path == "/" or path == "" then die("refusing to remove unsafe path") end
  local ok = os.execute("rm -rf " .. q(path))
  if ok ~= true and ok ~= 0 then die("rm failed: " .. path) end
end

local function cp_r(src, dst)
  local ok = os.execute("cp -R " .. q(src) .. " " .. q(dst))
  if ok ~= true and ok ~= 0 then die("copy failed: " .. src .. " -> " .. dst) end
end

local function cp_file(src, dst)
  local ok = os.execute("cp " .. q(src) .. " " .. q(dst))
  if ok ~= true and ok ~= 0 then die("copy failed: " .. src .. " -> " .. dst) end
end

local function read_file(path, mode)
  local f = assert(io.open(path, mode or "rb"))
  local data = f:read("*a")
  f:close()
  return data
end

local function write_file(path, data, mode)
  local parent = path:match("^(.*)/[^/]+$")
  if parent then mkdir_p(parent) end
  local f = assert(io.open(path, mode or "wb"))
  f:write(data)
  f:close()
end

local function list_dir(path)
  local items = {}
  if not lfs then
    local h = io.popen("find " .. q(path) .. " -mindepth 1 -maxdepth 1 -print")
    for line in h:lines() do table.insert(items, line:match("[^/]+$")) end
    h:close()
    table.sort(items)
    return items
  end
  for item in lfs.dir(path) do
    if item ~= "." and item ~= ".." then table.insert(items, item) end
  end
  table.sort(items)
  return items
end

local function run_capture(cmd)
  local h = io.popen(cmd .. " 2>&1")
  local out = h:read("*a")
  local ok, _, code = h:close()
  if not ok then return nil, out, code or 1 end
  return out, nil, 0
end

local function run(cmd)
  local ok = os.execute(cmd)
  if ok ~= true and ok ~= 0 then die("command failed: " .. cmd) end
end

local function b3_file(path)
  local out, err = run_capture("b3sum --no-names " .. q(path))
  if not out then die(err) end
  return "b3:" .. out:match("^%s*([0-9a-fA-F]+)")
end

local function b3_data(data)
  local tmp = os.tmpname()
  write_file(tmp, data)
  local hash = b3_file(tmp)
  os.remove(tmp)
  return hash
end

local function filesize(path)
  if lfs then return assert(lfs.attributes(path, "size")) end
  local out = assert(run_capture("wc -c < " .. q(path)))
  return tonumber(out:match("%d+"))
end

local function json_string(v)
  if json then return json.encode(v) end
  local parts = {}
  for _, item in ipairs(v) do parts[#parts + 1] = string.format("%q", item) end
  return "[" .. table.concat(parts, ",") .. "]"
end

local ARTIFACTS = {
  lua = {
    kind = "runtime",
    description = "Lua programming language runtime",
    versions = {
      ["5.4.7"] = { url = "https://www.lua.org/ftp/lua-5.4.7.tar.gz" },
      ["5.4.6"] = { url = "https://www.lua.org/ftp/lua-5.4.6.tar.gz" },
    },
    order = { "5.4.7", "5.4.6" },
  },
  inspect = {
    kind = "lib",
    description = "Human-readable representation of Lua tables",
    versions = {
      ["3.1.3"] = { url = "https://github.com/kikito/inspect.lua/archive/refs/tags/v3.1.3.tar.gz" },
      ["3.1.2"] = { url = "https://github.com/kikito/inspect.lua/archive/refs/tags/v3.1.2.tar.gz" },
    },
    order = { "3.1.3", "3.1.2" },
  },
  luassert = {
    kind = "lib",
    description = "Assertion library for Lua",
    versions = {
      ["1.9.0"] = { url = "https://github.com/Olivine-Labs/luassert/archive/refs/tags/v1.9.0.tar.gz" },
      ["1.8.0"] = { url = "https://github.com/Olivine-Labs/luassert/archive/refs/tags/v1.8.0.tar.gz" },
    },
    order = { "1.9.0", "1.8.0" },
  },
}
local ARTIFACT_ORDER = { "lua", "inspect", "luassert" }

local function parse_args(args)
  local opts, positional = {}, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a:sub(1, 2) == "--" then
      local key, val = a:match("^%-%-([^=]+)=(.*)$")
      if key then opts[key] = val else
        key = a:sub(3)
        if key == "clean" or key == "force" then opts[key] = true else
          i = i + 1
          opts[key] = args[i]
        end
      end
    else
      table.insert(positional, a)
    end
    i = i + 1
  end
  return opts, positional
end

local function cmd_generate_sandbox(args)
  local opts = parse_args(args)
  local sandbox = join(ROOT, "fixtures", "sandbox")
  local reference = join(ROOT, "fixtures", "sandbox-reference")
  if opts.clean and exists(sandbox) then
    print("--- Cleaning existing sandbox at " .. sandbox)
    rm_rf(sandbox)
  end
  if not exists(reference) then die("Reference directory not found at " .. reference) end
  print("--- Synchronizing sandbox from " .. reference)
  if exists(sandbox) then
    for _, project in ipairs({ "my-lib", "my-app" }) do
      local src, dst = join(reference, project), join(sandbox, project)
      if exists(src) then
        if exists(dst) then rm_rf(dst) end
        cp_r(src, dst)
        print("  Updated project: " .. project)
      end
    end
    for _, item in ipairs(list_dir(reference)) do
      if item:match("%.sh$") then
        cp_file(join(reference, item), join(sandbox, item))
        print("  Updated script: " .. item)
      end
    end
  else
    mkdir_p(sandbox:match("^(.*)/[^/]+$"))
    cp_r(reference, sandbox)
    print("  Initialized sandbox from reference")
  end
  print("\n✅ Sandbox ready.")
end

local function tar_create_from_cwd(src_dir, dest)
  run("find " .. q(src_dir) .. " -exec touch -t 197001010000 {} +")
  local gtar = run_capture("command -v gtar")
  if gtar and gtar:match("%S") then
    run("gtar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -czf " .. q(dest) .. " -C " .. q(src_dir) .. " .")
  else
    run("env COPYFILE_DISABLE=1 tar -czf " .. q(dest) .. " -C " .. q(src_dir) .. " .")
  end
end

local function create_tar_gz_from_dir(src_dir, dest)
  tar_create_from_cwd(src_dir, dest)
end

local function create_tar_gz(files, dest)
  local tmp = os.tmpname()
  os.remove(tmp)
  mkdir_p(tmp)
  for name, data in pairs(files) do write_file(join(tmp, name), data) end
  create_tar_gz_from_dir(tmp, dest)
  rm_rf(tmp)
end

local function cmd_generate_mock_rocks(args)
  local opts, positional = parse_args(args)
  local base_dir, port = positional[1], tonumber(positional[2])
  if not base_dir or not port then die("Usage: generate-mock-rocks <dir> <port>") end
  local mode = opts.mode or "ok"
  mkdir_p(base_dir)

  local c_source = [[
#include <lua.h>
#include <lauxlib.h>
static int hello(lua_State *L) { lua_pushstring(L, "hello from builtin c module"); return 1; }
int luaopen_builtin_cmodule(lua_State *L) { lua_newtable(L); lua_pushcfunction(L, hello); lua_setfield(L, -2, "hello"); return 1; }
]]
  create_tar_gz({ ["test_c.c"] = c_source }, join(base_dir, "builtin-cmodule-0.1.0.tar.gz"))

  local fakebin = [[
#!/usr/bin/env lua
print("lua_args: " .. table.concat(arg, " "))
]]
  create_tar_gz({ ["fake.lua"] = fakebin }, join(base_dir, "fakebin-1.0.tar.gz"))

  local rockspec_builtin = string.format([[package = "builtin-cmodule"
version = "0.1.0-1"
source = { url = "http://localhost:%d/builtin-cmodule-0.1.0.tar.gz" }
build = { type = "builtin", modules = { builtin_cmodule = "test_c.c" } }
dependencies = { "lua >= 5.1" }
]], port)
  local rockspec_fakebin = string.format([[package = "fakebin"
version = "1.0-1"
source = { url = "http://localhost:%d/fakebin-1.0.tar.gz" }
build = { type = "builtin", modules = { fake = "fake.lua" }, install = { bin = { "fake.lua" } } }
dependencies = { "lua >= 5.1" }
]], port)

  local child_lua = [[
return { hello = "from child" }
]]
  create_tar_gz({ ["child.lua"] = child_lua }, join(base_dir, "child-1.0.tar.gz"))
  local rockspec_child = string.format([[package = "child"
version = "1.0-1"
source = { url = "http://localhost:%d/child-1.0.tar.gz" }
build = { type = "builtin", modules = { child = "child.lua" } }
dependencies = { "lua >= 5.1" }
]], port)
  local parent_lua = [[
local child = require("child")
return { greet = function() return child.hello end }
]]
  create_tar_gz({ ["parent.lua"] = parent_lua }, join(base_dir, "parent-1.0.tar.gz"))
  local rockspec_parent = string.format([[package = "parent"
version = "1.0-1"
source = { url = "http://localhost:%d/parent-1.0.tar.gz" }
build = { type = "builtin", modules = { parent = "parent.lua" } }
dependencies = { "lua >= 5.1", "child >= 1.0" }
]], port)

  write_file(join(base_dir, "builtin-cmodule-0.1.0-1.rockspec"), rockspec_builtin)
  write_file(join(base_dir, "fakebin-1.0-1.rockspec"), rockspec_fakebin)
  write_file(join(base_dir, "child-1.0-1.rockspec"), rockspec_child)
  write_file(join(base_dir, "parent-1.0-1.rockspec"), rockspec_parent)

  local manifest = {
    repository = {
      ["builtin-cmodule"] = { ["0.1.0-1"] = { { arch = "rockspec" } } },
      fakebin = { ["1.0-1"] = { { arch = "rockspec" } } },
      child = { ["1.0-1"] = { { arch = "rockspec" } } },
      parent = { ["1.0-1"] = { { arch = "rockspec" } } },
    },
  }
  if mode == "invalid-json" then
    write_file(join(base_dir, "manifest-5.4.json"), "{ invalid json")
  elseif mode == "missing-repository" then
    write_file(join(base_dir, "manifest-5.4.json"), json_string({}))
  else
    write_file(join(base_dir, "manifest-5.4.json"), json_string(manifest))
  end

  print("Mock LuaRocks server started on port " .. port .. " (mode=" .. mode .. ")")
  local socket = require("socket")
  local server = assert(socket.bind("0.0.0.0", port))
  server:settimeout(nil)
  while true do
    local client = server:accept()
    if client then
      client:settimeout(5)
      local req = client:receive("*l") or ""
      local path = req:match("%S+%s+([^%s]+)") or "/"
      while true do local line = client:receive("*l"); if not line or line == "" then break end end
      path = path:gsub("^/", "")
      if path == "" then path = "manifest-5.4.json" end
      if path:match("^manifest%-") and mode == "manifest-500" then
        local body = "mock manifest error"
        client:send("HTTP/1.1 500 Internal Server Error\r\nContent-Length: " .. #body .. "\r\nConnection: close\r\n\r\n" .. body)
      elseif path:match("^manifest%-") and mode == "manifest-404" then
        local body = "mock manifest not found"
        client:send("HTTP/1.1 404 Not Found\r\nContent-Length: " .. #body .. "\r\nConnection: close\r\n\r\n" .. body)
      else
        local file_path = join(base_dir, path)
        local f = io.open(file_path, "rb")
        if f then
          local body = f:read("*a"); f:close()
          client:send("HTTP/1.1 200 OK\r\nContent-Length: " .. #body .. "\r\nConnection: close\r\n\r\n")
          client:send(body)
        else
          local body = "not found"
          client:send("HTTP/1.1 404 Not Found\r\nContent-Length: " .. #body .. "\r\nConnection: close\r\n\r\n" .. body)
        end
      end
      client:close()
    end
  end
end

local function cmd_fetch_registry_artifacts(args)
  local opts = parse_args(args)
  local cache_dir = opts["cache-dir"] or opts.c or die("--cache-dir is required")
  mkdir_p(cache_dir)
  for _, name in ipairs(ARTIFACT_ORDER) do
    local spec = ARTIFACTS[name]
    for _, version in ipairs(spec.order) do
      local url = spec.versions[version].url
      local dest = join(cache_dir, name .. "-" .. version .. ".tar.gz")
      if opts.force or not exists(dest) then
        print(string.format("[fetch] %s@%s from %s", name, version, url))
        run("curl -fL --retry 3 --connect-timeout 20 --max-time 120 -o " .. q(dest) .. " " .. q(url))
        print("[fetch] cached: " .. dest)
      end
    end
  end
  print("All artifacts fetched.")
end

local function toml_array(items)
  return json_string(items)
end

local function inline_array(items)
  if not items or #items == 0 then return "[]" end
  local out = {}
  for _, item in ipairs(items) do
    local fields = {}
    for _, key in ipairs(item.__order or { "name", "version", "abi", "path" }) do
      if item[key] ~= nil then fields[#fields + 1] = key .. " = " .. string.format("%q", item[key]) end
    end
    out[#out + 1] = "{ " .. table.concat(fields, ", ") .. " }"
  end
  return "[" .. table.concat(out, ", ") .. "]"
end

local function blob_path(hash)
  local h = hash:gsub("^b3:", "")
  return join("blobs", "b3", h:sub(1, 2), h:sub(3, 4), h .. ".tar.gz")
end

local function recipe_hash(info)
  local provides = info.provides
  local canonical = table.concat({
    "schema=moonstone.recipe.v0",
    "kind=prebuilt-artifact",
    "name=" .. info.name,
    "version=" .. info.version,
    "source_hash=" .. info.source_hash,
    "artifact_hash=" .. info.artifact_hash,
    "materializer=" .. (info.materialize and info.materialize.kind or "unpack-artifact-v0"),
    "target=" .. info.target,
    "lua_api=" .. (info.lua_api or ""),
    "lua_abi=" .. info.lua_abi,
    "runtime=" .. (info.runtime or ""),
    "runtime_artifact_hash=" .. (info.runtime_artifact_hash or ""),
    "strip_components=" .. tostring(info.strip_components),
    "provides=" .. inline_array(provides.runtime) .. inline_array(provides.bin) .. inline_array(provides.headers) .. inline_array(provides.native_lib) .. inline_array(provides.lua_module) .. inline_array(provides.lua_cmodule),
  }, "\n")
  return b3_data(canonical)
end

local function package_artifact_dir(src_dir, artifact_name, output_dir, strip_components)
  local out = join(output_dir, artifact_name)
  if strip_components == 0 then
    local tmp = os.tmpname(); os.remove(tmp); mkdir_p(tmp)
    run("cp -R " .. q(src_dir) .. "/. " .. q(tmp))
    tar_create_from_cwd(tmp, out)
    rm_rf(tmp)
  else
    run("cp " .. q(src_dir) .. " " .. q(out))
  end
  return out
end

local function unpack_tarball(tarball, dest)
  rm_rf(dest); mkdir_p(dest)
  run("tar -xzf " .. q(tarball) .. " -C " .. q(dest))
end

local function single_root(dir)
  local items = list_dir(dir)
  if #items == 1 and is_dir(join(dir, items[1])) then return join(dir, items[1]) end
  return dir
end

local function build_lua(raw, version, output_dir)
  local name = "lua"
  local artifact_name = string.format("lua-%s.tar.gz", version)
  local dest = join(output_dir, artifact_name)
  cp_file(raw, dest)
  local hash = b3_file(dest)
  return {
    name = name, version = version, kind = "runtime", description = "Lua " .. version .. " source runtime",
    source_hash = hash, artifact_hash = hash, artifact_path = dest, artifact_name = artifact_name, artifact_bytes = filesize(dest),
    runtimes = { "lua@" .. version }, lua_api = "lua-5.4", lua_abi = "lua-5.4", runtime = "lua@" .. version,
    runtime_artifact_hash = hash, target = "source", strip_components = 1,
    materialize = { kind = "command", lua_runtime = true },
    provides = {
      runtime = { { name = "lua", version = version, abi = "lua-5.4", __order = { "name", "version", "abi" } } },
      bin = { { name = "lua", path = "bin/lua" }, { name = "luac", path = "bin/luac" } },
      headers = { { name = "lua.h", path = "include/lua.h" }, { name = "luaconf.h", path = "include/luaconf.h" }, { name = "lualib.h", path = "include/lualib.h" }, { name = "lauxlib.h", path = "include/lauxlib.h" }, { name = "lua.hpp", path = "include/lua.hpp" } },
      native_lib = { { name = "lua", path = "lib/liblua.a" } }, lua_module = {}, lua_cmodule = {},
    },
  }
end

local function build_lua_module(raw, name, version, output_dir, module_src)
  local tmp = os.tmpname(); os.remove(tmp); mkdir_p(tmp)
  unpack_tarball(raw, tmp)
  local root = single_root(tmp)
  local pack = os.tmpname(); os.remove(pack); mkdir_p(pack); mkdir_p(join(pack, "lua"))
  cp_file(join(root, module_src), join(pack, "lua", name .. ".lua"))
  local artifact_name = name .. "-" .. version .. ".tar.gz"
  local artifact_path = join(output_dir, artifact_name)
  tar_create_from_cwd(pack, artifact_path)
  rm_rf(tmp); rm_rf(pack)
  return {
    name = name, version = version, kind = "lib",
    description = ARTIFACTS[name].description,
    source_hash = b3_file(raw), artifact_hash = b3_file(artifact_path), artifact_path = artifact_path,
    artifact_name = artifact_name, artifact_bytes = filesize(artifact_path), runtimes = { "lua@5.4.7" },
    lua_api = "lua-5.4", lua_abi = "lua-5.4", runtime = "lua@5.4.7", runtime_artifact_hash = "",
    target = "any", strip_components = 0,
    provides = { runtime = {}, bin = {}, headers = {}, native_lib = {}, lua_module = { { name = name, path = "lua/" .. name .. ".lua" } }, lua_cmodule = {} },
  }
end

local function build_luassert(raw, version, output_dir)
  local tmp = os.tmpname(); os.remove(tmp); mkdir_p(tmp)
  unpack_tarball(raw, tmp)
  local root = single_root(tmp)
  local pack = os.tmpname(); os.remove(pack); mkdir_p(pack); mkdir_p(join(pack, "lua"))
  local src = join(root, "src")
  if is_dir(src) then
    run("cp -R " .. q(src) .. "/. " .. q(join(pack, "lua")))
    if exists(join(src, "init.lua")) then cp_file(join(src, "init.lua"), join(pack, "lua", "luassert.lua")) end
  else
    run("find " .. q(root) .. " -name '*.lua' -exec cp {} " .. q(join(pack, "lua")) .. " \\;")
  end
  local artifact_name = "luassert-" .. version .. ".tar.gz"
  local artifact_path = join(output_dir, artifact_name)
  tar_create_from_cwd(pack, artifact_path)
  rm_rf(tmp); rm_rf(pack)
  return {
    name = "luassert", version = version, kind = "lib", description = ARTIFACTS.luassert.description,
    source_hash = b3_file(raw), artifact_hash = b3_file(artifact_path), artifact_path = artifact_path,
    artifact_name = artifact_name, artifact_bytes = filesize(artifact_path), runtimes = { "lua@5.4.7" },
    lua_api = "lua-5.4", lua_abi = "lua-5.4", runtime = "lua@5.4.7", runtime_artifact_hash = "",
    target = "any", strip_components = 0,
    provides = { runtime = {}, bin = {}, headers = {}, native_lib = {}, lua_module = { { name = "luassert", path = "lua/luassert.lua" } }, lua_cmodule = {} },
  }
end

local function build_synthetic_cmodule(output_dir)
  local src = [[
#include <lua.h>
#include <lauxlib.h>
static int hello(lua_State *L) { lua_pushstring(L, "hello from synthetic cmodule"); return 1; }
int luaopen_synthetic_cmodule(lua_State *L) { lua_newtable(L); lua_pushcfunction(L, hello); lua_setfield(L, -2, "hello"); return 1; }
]]
  local artifact_name = "synthetic-cmodule-0.1.0-source.tar.gz"
  local path = join(output_dir, artifact_name)
  create_tar_gz({ ["synthetic_cmodule.c"] = src }, path)
  local hash = b3_file(path)
  return { name = "synthetic-cmodule", version = "0.1.0", kind = "lib", description = "Synthetic C module for testing materialization", source_hash = hash, artifact_hash = hash, artifact_path = path, artifact_name = artifact_name, artifact_bytes = filesize(path), runtimes = { "lua@5.4.7" }, lua_api = "lua-5.4", lua_abi = "lua-5.4", runtime = "lua@5.4.7", runtime_artifact_hash = "", target = "source", strip_components = 0, materialize = { kind = "native-cmodule" }, provides = { runtime = {}, bin = {}, headers = {}, native_lib = {}, lua_module = {}, lua_cmodule = { { name = "synthetic_cmodule.so", path = "synthetic_cmodule.so" } } } }
end

local function build_synthetic_make(output_dir)
  local c = [[
#include <lua.h>
#include <lauxlib.h>
static int hello(lua_State *L) { lua_pushstring(L, "hello from synthetic make module"); return 1; }
int luaopen_synthetic_make_module(lua_State *L) { lua_newtable(L); lua_pushcfunction(L, hello); lua_setfield(L, -2, "hello"); return 1; }
]]
  local makefile = [[
CC ?= cc
LUA_INCDIR ?= .
CFLAGS = -shared -fPIC -I$(LUA_INCDIR)
ifeq ($(shell uname), Darwin)
  CFLAGS = -shared -fPIC -I$(LUA_INCDIR) -undefined dynamic_lookup
endif
all: synthetic_make_module.so
synthetic_make_module.so: synthetic_make_module.c
	$(CC) $(CFLAGS) -o $@ $<
install: synthetic_make_module.so
	mkdir -p $(PREFIX)
	cp $< $(PREFIX)/
]]
  local artifact_name = "synthetic-make-module-0.1.0-source.tar.gz"
  local path = join(output_dir, artifact_name)
  create_tar_gz({ ["synthetic_make_module.c"] = c, Makefile = makefile }, path)
  local hash = b3_file(path)
  return { name = "synthetic-make-module", version = "0.1.0", kind = "lib", description = "Synthetic C module using Makefile", source_hash = hash, artifact_hash = hash, artifact_path = path, artifact_name = artifact_name, artifact_bytes = filesize(path), runtimes = { "lua@5.4.7" }, lua_api = "lua-5.4", lua_abi = "lua-5.4", runtime = "lua@5.4.7", runtime_artifact_hash = "", target = "source", strip_components = 0, materialize = { kind = "command", make = true }, provides = { runtime = {}, bin = {}, headers = {}, native_lib = {}, lua_module = {}, lua_cmodule = { { name = "synthetic_make_module.so", path = "synthetic_make_module.so" } } } }
end

local function build_synthetic_cmake(output_dir)
  local c = [[
#include <lua.h>
#include <lauxlib.h>
static int hello(lua_State *L) { lua_pushstring(L, "hello from synthetic cmake module"); return 1; }
__attribute__((visibility("default"))) int luaopen_synthetic_cmake_module(lua_State *L) { lua_newtable(L); lua_pushcfunction(L, hello); lua_setfield(L, -2, "hello"); return 1; }
]]
  local cmake = [[
cmake_minimum_required(VERSION 3.10)
project(synthetic_cmake_module C)
set(CMAKE_C_VISIBILITY_PRESET default)
add_library(synthetic_cmake_module MODULE synthetic_cmake_module.c)
set_target_properties(synthetic_cmake_module PROPERTIES PREFIX "" OUTPUT_NAME "synthetic_cmake_module" SUFFIX ".so")
target_include_directories(synthetic_cmake_module PRIVATE ${LUA_INCLUDE_DIR})
]]
  local artifact_name = "synthetic-cmake-module-0.1.0-source.tar.gz"
  local path = join(output_dir, artifact_name)
  create_tar_gz({ ["synthetic_cmake_module.c"] = c, ["CMakeLists.txt"] = cmake }, path)
  local hash = b3_file(path)
  return { name = "synthetic-cmake-module", version = "0.1.0", kind = "lib", description = "Synthetic C module for testing CMake materialization", source_hash = hash, artifact_hash = hash, artifact_path = path, artifact_name = artifact_name, artifact_bytes = filesize(path), runtimes = { "lua@5.4.7" }, lua_api = "lua-5.4", lua_abi = "lua-5.4", runtime = "lua@5.4.7", runtime_artifact_hash = "", target = "source", strip_components = 0, materialize = { kind = "cmake" }, provides = { runtime = {}, bin = {}, headers = {}, native_lib = {}, lua_module = {}, lua_cmodule = { { name = "synthetic_cmake_module.so", path = "synthetic_cmake_module.so" } } } }
end

local function write_descriptor(path, info)
  local p = info.provides
  local artifact_kind = info.materialize and "source" or (info.kind == "runtime" and "runtime" or "lua_module")
  local artifact_id = artifact_kind .. "-" .. info.target .. "-" .. info.lua_abi
  local lines = {
    "[package]", 'name = "' .. info.name .. '"', 'version = "' .. info.version .. '"', 'kind = "' .. info.kind .. '"', 'description = "' .. info.description .. '"', "",
    "[[artifacts]]", 'id = "' .. artifact_id .. '"', 'kind = "' .. artifact_kind .. '"', 'target = "' .. info.target .. '"', 'lua_api = "' .. info.lua_api .. '"', 'lua_abi = "' .. info.lua_abi .. '"', 'runtime = "' .. info.runtime .. '"', 'format = "tar.gz"', 'url = "' .. blob_path(info.artifact_hash) .. '"', 'hash = "' .. info.artifact_hash .. '"', 'recipe_hash = "' .. info.recipe_hash .. '"', 'bytes = ' .. info.artifact_bytes, "",
  }
  if info.runtime_artifact_hash ~= "" then lines[#lines + 1] = 'runtime_artifact_hash = "' .. info.runtime_artifact_hash .. '"'; lines[#lines + 1] = "" end
  if info.materialize then
    if info.materialize.lua_runtime then
      lines[#lines + 1] = "[artifacts.materialize]"; lines[#lines + 1] = 'type = "command"'; lines[#lines + 1] = "strip_components = " .. info.strip_components; lines[#lines + 1] = ""
      lines[#lines + 1] = "[[artifacts.materialize.steps]]"; lines[#lines + 1] = 'command = "make"'; lines[#lines + 1] = 'args = ["generic", "CC=zig cc", "MYCFLAGS=-fPIC -DLUA_USE_POSIX -DLUA_USE_DLOPEN", "MYLDFLAGS=-Wl,-E", "MYLIBS=-lm -ldl"]'; lines[#lines + 1] = ""
      lines[#lines + 1] = "[artifacts.materialize.collect]"; lines[#lines + 1] = 'bins = [{ name = "bin/lua", path = "${source}/src/lua" }, { name = "bin/luac", path = "${source}/src/luac" }]'; lines[#lines + 1] = 'headers = [{ name = "include/lua.h", path = "${source}/src/lua.h" }, { name = "include/luaconf.h", path = "${source}/src/luaconf.h" }, { name = "include/lualib.h", path = "${source}/src/lualib.h" }, { name = "include/lauxlib.h", path = "${source}/src/lauxlib.h" }, { name = "include/lua.hpp", path = "${source}/src/lua.hpp" }]'; lines[#lines + 1] = 'native_lib = [{ name = "lib/liblua.a", path = "${source}/src/liblua.a" }]'; lines[#lines + 1] = ""
    elseif info.materialize.kind == "native-cmodule" then
      lines[#lines + 1] = "[artifacts.materialize]"; lines[#lines + 1] = 'type = "native_cmodule"'; lines[#lines + 1] = "strip_components = " .. info.strip_components; lines[#lines + 1] = 'strategy = "zig-cc"'; lines[#lines + 1] = ""; lines[#lines + 1] = "[artifacts.materialize.input]"; lines[#lines + 1] = 'sources = ["synthetic_cmodule.c"]'; lines[#lines + 1] = ""; lines[#lines + 1] = "[artifacts.materialize.output]"; lines[#lines + 1] = 'module = "synthetic_cmodule"'; lines[#lines + 1] = 'path = "synthetic_cmodule.so"'; lines[#lines + 1] = ""
    elseif info.materialize.make then
      lines[#lines + 1] = "[artifacts.materialize]"; lines[#lines + 1] = 'type = "command"'; lines[#lines + 1] = "strip_components = " .. info.strip_components; lines[#lines + 1] = 'command = "make"'; lines[#lines + 1] = 'args = ["install", "PREFIX=${out}"]'; lines[#lines + 1] = "[artifacts.materialize.env]"; lines[#lines + 1] = 'LUA_INCDIR = "${runtime.include}"'; lines[#lines + 1] = ""; lines[#lines + 1] = "[artifacts.materialize.collect]"; lines[#lines + 1] = 'lua_cmodules = [{ name = "synthetic_make_module.so", path = "${out}/synthetic_make_module.so" }]'; lines[#lines + 1] = ""
    elseif info.materialize.kind == "cmake" then
      lines[#lines + 1] = "[artifacts.materialize]"; lines[#lines + 1] = 'type = "cmake"'; lines[#lines + 1] = "strip_components = " .. info.strip_components; lines[#lines + 1] = ""; lines[#lines + 1] = "[artifacts.materialize.collect]"; lines[#lines + 1] = 'lua_cmodules = [{ name = "synthetic_cmake_module.so", path = "${build}/synthetic_cmake_module.so" }]'; lines[#lines + 1] = ""
    end
  else
    lines[#lines + 1] = "[artifacts.materialize]"; lines[#lines + 1] = 'type = "archive"'; lines[#lines + 1] = "strip_components = " .. info.strip_components; lines[#lines + 1] = ""
  end
  for _, provision in ipairs(p.runtime) do lines[#lines + 1] = "[[artifacts.provides]]"; lines[#lines + 1] = 'kind = "runtime"'; lines[#lines + 1] = 'name = "' .. provision.name .. '"'; lines[#lines + 1] = 'version = "' .. provision.version .. '"'; lines[#lines + 1] = 'lua_abi = "' .. provision.abi .. '"'; lines[#lines + 1] = "" end
  for _, pair in ipairs({ { "bin", p.bin }, { "include", p.headers }, { "lib", p.native_lib }, { "lua_module", p.lua_module }, { "lua_cmodule", p.lua_cmodule } }) do for _, provision in ipairs(pair[2]) do lines[#lines + 1] = "[[artifacts.provides]]"; lines[#lines + 1] = 'kind = "' .. pair[1] .. '"'; lines[#lines + 1] = 'name = "' .. provision.name .. '"'; lines[#lines + 1] = 'path = "' .. provision.path .. '"'; lines[#lines + 1] = "" end end
  write_file(path, table.concat(lines, "\n") .. "\n")
end

local function write_store_manifest(path, info)
  write_file(path, table.concat({
    "[artifact]", 'name = "' .. info.name .. '"', 'version = "' .. info.version .. '"', 'kind = "' .. info.kind .. '"', 'source_hash = "' .. info.source_hash .. '"', 'recipe_hash = "' .. info.recipe_hash .. '"', 'artifact_hash = "' .. info.artifact_hash .. '"', 'target = "' .. info.target .. '"', "",
    "[compat]", 'runtime_version = "' .. info.runtime .. '"', 'lua_abi = "' .. info.lua_abi .. '"', 'runtime_artifact_hash = "' .. info.runtime_artifact_hash .. '"', "",
    "[provides]", "runtime = " .. inline_array(info.provides.runtime), "bin = " .. inline_array(info.provides.bin), "headers = " .. inline_array(info.provides.headers), "native_lib = " .. inline_array(info.provides.native_lib), "lua_module = " .. inline_array(info.provides.lua_module), "lua_cmodule = " .. inline_array(info.provides.lua_cmodule), "",
  }, "\n"))
end

local function sql_quote(value)
  if value == nil then return "NULL" end
  return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function write_index(registry_dir, infos)
  local chunks = {}
  for _, info in ipairs(infos) do
    local desc = join("packages", info.name, info.version, "package.toml")
    info.descriptor = desc
    info.descriptor_hash = b3_file(join(registry_dir, desc))
    chunks[#chunks + 1] = table.concat({ "[[package]]", 'name = "' .. info.name .. '"', 'version = "' .. info.version .. '"', 'kind = "' .. info.kind .. '"', 'descriptor = "' .. desc .. '"', 'descriptor_hash = "' .. info.descriptor_hash .. '"', "targets = " .. toml_array({ info.target }), "runtimes = " .. toml_array(info.runtimes), "" }, "\n")
  end
  local content = table.concat(chunks, "\n")
  local index_path = join(registry_dir, "index.toml")
  write_file(index_path, content)
  local index_hash, index_bytes = b3_file(index_path), filesize(index_path)

  local sqlite_path = join(registry_dir, "index.sqlite")
  local zst_path = join(registry_dir, "index.sqlite.zst")
  os.remove(sqlite_path); os.remove(zst_path)

  local sql = {
    "PRAGMA journal_mode = DELETE;", "PRAGMA synchronous = OFF;",
    "CREATE TABLE packages (name TEXT NOT NULL, version TEXT NOT NULL, kind TEXT NOT NULL, descriptor TEXT NOT NULL, descriptor_hash TEXT NOT NULL, yanked INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (name, version));",
    "CREATE TABLE package_runtimes (name TEXT NOT NULL, version TEXT NOT NULL, runtime TEXT NOT NULL, lua_api TEXT, lua_abi TEXT, PRIMARY KEY (name, version, runtime));",
    "CREATE TABLE package_targets (name TEXT NOT NULL, version TEXT NOT NULL, target TEXT NOT NULL, PRIMARY KEY (name, version, target));",
    "CREATE TABLE artifacts (name TEXT NOT NULL, version TEXT NOT NULL, artifact_hash TEXT NOT NULL, source_hash TEXT, recipe_hash TEXT NOT NULL, target TEXT, runtime TEXT, runtime_artifact_hash TEXT, lua_api TEXT, lua_abi TEXT, url TEXT NOT NULL, bytes INTEGER, format TEXT NOT NULL, PRIMARY KEY (name, version, artifact_hash));",
    "CREATE TABLE provides_lua (name TEXT NOT NULL, version TEXT NOT NULL, artifact_hash TEXT NOT NULL, module TEXT NOT NULL, path TEXT NOT NULL, lua_abi TEXT, PRIMARY KEY (artifact_hash, module));",
    "CREATE TABLE provides_bin (name TEXT NOT NULL, version TEXT NOT NULL, artifact_hash TEXT NOT NULL, bin TEXT NOT NULL, path TEXT NOT NULL, PRIMARY KEY (artifact_hash, bin));",
    "CREATE TABLE provides_headers (name TEXT NOT NULL, version TEXT NOT NULL, artifact_hash TEXT NOT NULL, header TEXT NOT NULL, path TEXT NOT NULL, PRIMARY KEY (artifact_hash, header));",
    "CREATE TABLE provides_lua_cmodule (name TEXT NOT NULL, version TEXT NOT NULL, artifact_hash TEXT NOT NULL, module TEXT NOT NULL, path TEXT NOT NULL, lua_abi TEXT, PRIMARY KEY (artifact_hash, module));",
  }
  for _, info in ipairs(infos) do
    sql[#sql + 1] = string.format("INSERT INTO packages (name, version, kind, descriptor, descriptor_hash) VALUES (%s,%s,%s,%s,%s);", sql_quote(info.name), sql_quote(info.version), sql_quote(info.kind), sql_quote(info.descriptor), sql_quote(info.descriptor_hash))
    if info.runtime and info.runtime ~= "" then
      sql[#sql + 1] = string.format("INSERT INTO package_runtimes (name, version, runtime, lua_api, lua_abi) VALUES (%s,%s,%s,%s,%s);", sql_quote(info.name), sql_quote(info.version), sql_quote(info.runtime), sql_quote(info.lua_api), sql_quote(info.lua_abi))
    end
    sql[#sql + 1] = string.format("INSERT INTO package_targets (name, version, target) VALUES (%s,%s,%s);", sql_quote(info.name), sql_quote(info.version), sql_quote(info.target))
    sql[#sql + 1] = string.format("INSERT INTO artifacts (name, version, artifact_hash, source_hash, recipe_hash, target, runtime, runtime_artifact_hash, lua_api, lua_abi, url, bytes, format) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%d,%s);", sql_quote(info.name), sql_quote(info.version), sql_quote(info.artifact_hash), sql_quote(info.source_hash), sql_quote(info.recipe_hash), sql_quote(info.target), sql_quote(info.runtime), sql_quote(info.runtime_artifact_hash), sql_quote(info.lua_api), sql_quote(info.lua_abi), sql_quote(blob_path(info.artifact_hash)), info.artifact_bytes, sql_quote("tar.gz"))
    for _, m in ipairs(info.provides.lua_module or {}) do sql[#sql + 1] = string.format("INSERT INTO provides_lua (name, version, artifact_hash, module, path, lua_abi) VALUES (%s,%s,%s,%s,%s,%s);", sql_quote(info.name), sql_quote(info.version), sql_quote(info.artifact_hash), sql_quote(m.name), sql_quote(m.path), sql_quote(info.lua_abi)) end
    for _, b in ipairs(info.provides.bin or {}) do sql[#sql + 1] = string.format("INSERT INTO provides_bin (name, version, artifact_hash, bin, path) VALUES (%s,%s,%s,%s,%s);", sql_quote(info.name), sql_quote(info.version), sql_quote(info.artifact_hash), sql_quote(b.name), sql_quote(b.path)) end
    for _, h in ipairs(info.provides.headers or {}) do sql[#sql + 1] = string.format("INSERT INTO provides_headers (name, version, artifact_hash, header, path) VALUES (%s,%s,%s,%s,%s);", sql_quote(info.name), sql_quote(info.version), sql_quote(info.artifact_hash), sql_quote(h.name), sql_quote(h.path)) end
    for _, m in ipairs(info.provides.lua_cmodule or {}) do sql[#sql + 1] = string.format("INSERT INTO provides_lua_cmodule (name, version, artifact_hash, module, path, lua_abi) VALUES (%s,%s,%s,%s,%s,%s);", sql_quote(info.name), sql_quote(info.version), sql_quote(info.artifact_hash), sql_quote(m.name), sql_quote(m.path), sql_quote(info.lua_abi)) end
  end
  sql[#sql + 1] = "VACUUM;"
  local sql_path = join(registry_dir, "index.sql")
  write_file(sql_path, table.concat(sql, "\n") .. "\n")
  run("sqlite3 " .. q(sqlite_path) .. " < " .. q(sql_path) .. " >/dev/null")
  os.remove(sql_path)
  local content_hash, content_bytes = b3_file(sqlite_path), filesize(sqlite_path)
  run("zstd -q -f " .. q(sqlite_path) .. " -o " .. q(zst_path))
  os.remove(sqlite_path)
  local compact_hash, compact_bytes = b3_file(zst_path), filesize(zst_path)
  return index_hash, index_bytes, compact_hash, compact_bytes, content_hash, content_bytes
end

local function write_registry_toml(registry_dir, index_hash, index_bytes, compact_hash, compact_bytes, content_hash, content_bytes)
  local lines = { "[registry]", 'id = "moonstone-synthetic"', 'name = "Synthetic Test Registry"', 'protocol = "moonstone.registry.v0"', 'revision = 1', 'generated_at = "2026-05-17T00:00:00Z"', 'min_client = "0.1.0"', "", "[index]", 'format = "toml"', 'url = "index.toml"', 'hash = "' .. index_hash .. '"', 'bytes = ' .. index_bytes, 'revision = 1' }
  if compact_hash ~= "" then
    lines[#lines + 1] = ""; lines[#lines + 1] = "[index.compact]"; lines[#lines + 1] = 'format = "sqlite-zstd"'; lines[#lines + 1] = 'url = "index.sqlite.zst"'; lines[#lines + 1] = 'compressed_hash = "' .. compact_hash .. '"'; lines[#lines + 1] = 'compressed_bytes = ' .. compact_bytes; lines[#lines + 1] = 'content_hash = "' .. content_hash .. '"'; lines[#lines + 1] = 'content_bytes = ' .. content_bytes; lines[#lines + 1] = 'revision = 1'
  end
  lines[#lines + 1] = ""; lines[#lines + 1] = "[blobs]"; lines[#lines + 1] = 'algorithm = "blake3"'; lines[#lines + 1] = 'layout = "shard"'; lines[#lines + 1] = ""; lines[#lines + 1] = "[capabilities]"; lines[#lines + 1] = 'runtimes = true'; lines[#lines + 1] = 'artifacts = true'; lines[#lines + 1] = 'source_packages = true'; lines[#lines + 1] = 'rocks_bridge = false'; lines[#lines + 1] = 'private = false'
  write_file(join(registry_dir, "registry.toml"), table.concat(lines, "\n") .. "\n")
end

local function cmd_registry_builder(args)
  local opts = parse_args(args)
  if opts.verify then return cmd_registry_verify({ opts.verify }) end
  local cache_dir = opts["cache-dir"] or join(ROOT, "fixtures", "sandbox", ".cache")
  local output_dir = opts["output-dir"] or "sandbox"
  if opts.clean and exists(output_dir) then rm_rf(output_dir) end
  mkdir_p(output_dir)
  cmd_fetch_registry_artifacts({ "--cache-dir", cache_dir })
  local infos = {}
  for _, name in ipairs(ARTIFACT_ORDER) do
    for _, version in ipairs(ARTIFACTS[name].order) do
      local raw = join(cache_dir, name .. "-" .. version .. ".tar.gz")
      local info
      if name == "lua" then info = build_lua(raw, version, output_dir)
      elseif name == "inspect" then info = build_lua_module(raw, name, version, output_dir, "inspect.lua")
      elseif name == "luassert" then info = build_luassert(raw, version, output_dir) end
      info.recipe_hash = recipe_hash(info)
      infos[#infos + 1] = info
    end
  end
  for _, builder in ipairs({ build_synthetic_cmodule, build_synthetic_make, build_synthetic_cmake }) do
    local info = builder(output_dir); info.recipe_hash = recipe_hash(info); infos[#infos + 1] = info
  end
  local registry_dir = join(output_dir, "registry")
  mkdir_p(join(registry_dir, "blobs", "b3"))
  for _, info in ipairs(infos) do
    local dest = join(registry_dir, blob_path(info.artifact_hash))
    mkdir_p(dest:match("^(.*)/[^/]+$"))
    run("mv " .. q(info.artifact_path) .. " " .. q(dest))
    info.artifact_path = dest
    print("[registry] blob: " .. dest)
  end
  for _, info in ipairs(infos) do
    local desc = join(registry_dir, "packages", info.name, info.version, "package.toml")
    write_descriptor(desc, info)
    print("[registry] descriptor: " .. desc)
  end
  local ih, ib, ch, cb, coh, cob = write_index(registry_dir, infos)
  print(string.format("[registry] index.toml: %s (%d bytes)", ih, ib))
  write_registry_toml(registry_dir, ih, ib, ch, cb, coh, cob)
  print("[registry] registry.toml")
  local artifacts = join(output_dir, "artifacts"); mkdir_p(artifacts)
  for _, info in ipairs(infos) do
    local manifest = join(artifacts, info.name .. "-" .. info.version .. "-manifest.toml")
    write_store_manifest(manifest, info)
    print("[registry] manifest: " .. manifest)
  end
  print("\nRegistry built at: " .. registry_dir)
end

function cmd_registry_verify(args)
  local registry_dir = args[1] or die("registry-verify <registry-dir>")
  local registry = join(registry_dir, "registry.toml")
  local index = join(registry_dir, "index.toml")
  if not exists(registry) then die("missing registry.toml") end
  if not exists(index) then die("missing index.toml") end
  local content = read_file(registry)
  local expected = content:match('hash = "(b3:[0-9a-f]+)"')
  local actual = b3_file(index)
  if expected and expected ~= actual then die("index hash mismatch: expected " .. expected .. ", got " .. actual) end
  print("OK: index.toml hash matches")
  for desc in read_file(index):gmatch('descriptor = "([^"]+)"') do
    if not exists(join(registry_dir, desc)) then die("missing descriptor: " .. desc) end
  end
  print("Registry verification passed")
end

local commands = {
  ["generate-sandbox"] = cmd_generate_sandbox,
  ["generate-mock-rocks"] = cmd_generate_mock_rocks,
  ["fetch-registry-artifacts"] = cmd_fetch_registry_artifacts,
  ["registry-builder"] = cmd_registry_builder,
  ["registry-verify"] = cmd_registry_verify,
}

local args = { ... }
local command = table.remove(args, 1)
if not command or command == "help" or command == "--help" then
  print("Usage: moon-tools <generate-sandbox|generate-mock-rocks|fetch-registry-artifacts|registry-builder|registry-verify> [args]")
  os.exit(command and 0 or 1)
end
local fn = commands[command]
if not fn then die("unknown command: " .. command) end
fn(args)
