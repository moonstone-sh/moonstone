-- Cross-checks src/core/assets/lua/moonstone/variants.lua against the cases
-- in src/core/platform/flavor.zig. Plain asserts so it runs on any Lua:
--   lua tests/lua/variants_spec.lua      luajit tests/lua/variants_spec.lua
local here = string.match(arg[0], "^(.*)[/\\]") or "."
package.path = here .. "/../../src/core/assets/lua/?.lua;" .. package.path
local variants = require("moonstone.variants")

local function flavor(family, level, os, arch)
  return { family = family, level = level, os = os, arch = arch, id = family .. level }
end

local function parse_all(names)
  local out = {}
  for index, name in ipairs(names) do out[index] = assert(variants.parse(name)) end
  return out
end

local passed = 0
local function case(name, fn)
  fn()
  passed = passed + 1
  print("ok - " .. name)
end

case("ordinary names are not variants", function()
  assert(variants.parse("lexer.lua") == nil)
  assert(variants.parse("parser_luajit.lua") == nil)
  assert(variants.parse("mail@example.lua") == nil)
  assert(variants.parse("@lua54.lua") == nil)
  assert(variants.parse("lexer@lua53@lua54.lua") == false)
  assert(variants.parse("lexer@linux@lua54.lua") == false)
end)

case("variant parts", function()
  local v = variants.parse("lexer@lua51@windows.lua")
  assert(v.stem == "lexer" and v.ext == ".lua")
  assert(v.tags[1] == "lua51" and v.tags[2] == "windows")
end)

case("exact language beats the fallback", function()
  local choice, index = variants.select(parse_all({ "lexer@lua51.lua", "lexer@lua54.lua" }), true, flavor("lua", 54, "linux", "x86_64"))
  assert(choice == "variant" and index == 2)
end)

case("fallback when no tag applies, none without one", function()
  local candidates = parse_all({ "lexer@lua51.lua" })
  local f = flavor("lua", 54, "linux", "x86_64")
  assert(variants.select(candidates, true, f) == "base")
  assert(variants.select(candidates, false, f) == "none")
end)

case("luajit prefers its own tag over lua51 and accepts lua51 alone", function()
  local jit = flavor("luajit", 51, "linux", "x86_64")
  local choice, index = variants.select(parse_all({ "lexer@lua51.lua", "lexer@luajit.lua" }), false, jit)
  assert(choice == "variant" and index == 2)
  choice, index = variants.select(parse_all({ "lexer@lua51.lua" }), false, jit)
  assert(choice == "variant" and index == 1)
end)

case("luau does not inherit lua51", function()
  assert(variants.select(parse_all({ "lexer@lua51.lua" }), true, flavor("luau", 51, "linux", "x86_64")) == "base")
end)

case("more tags on the same dimensions win", function()
  local choice, index = variants.select(parse_all({ "fs@lua54.lua", "fs@lua54@windows.lua" }), false, flavor("lua", 54, "windows", "x86_64"))
  assert(choice == "variant" and index == 2)
end)

case("specific on different dimensions is ambiguous", function()
  assert(variants.select(parse_all({ "fs@lua54.lua", "fs@linux.lua" }), true, flavor("lua", 54, "linux", "x86_64")) == "ambiguous")
end)

case("suffixes are canonical and cover every match", function()
  local list = variants.suffixes(flavor("luajit", 51, "linux", "x86_64"))
  local seen = {}
  for _, suffix in ipairs(list) do
    local v = assert(variants.parse("m" .. suffix .. ".lua"))
    assert(variants.match(v, flavor("luajit", 51, "linux", "x86_64")))
    seen[suffix] = true
  end
  assert(seen["@luajit"] and seen["@lua51@linux@x86_64"] and seen["@x86_64"])
  assert(#list == 11)
end)

case("resolve finds a project's own variants on a path", function()
  local dir = os.tmpname()
  os.remove(dir)
  assert(os.execute("mkdir -p '" .. dir .. "/pkg'"))
  local function write(name, body)
    local file = assert(io.open(dir .. "/" .. name, "w"))
    file:write(body)
    file:close()
  end
  write("pkg/a.lua", "return 'base'")
  write("pkg/a@lua54.lua", "return 'lua54'")
  write("pkg/b@lua51.lua", "return 'lua51'")
  write("pkg/c@lua54.lua", "")
  write("pkg/c@linux.lua", "")
  local path = dir .. "/?.lua"
  local f = flavor("lua", 54, "linux", "x86_64")
  assert(variants.resolve("pkg.a", f, path) == dir .. "/pkg/a@lua54.lua")
  assert(variants.resolve("pkg.b", f, path) == nil)
  assert(not pcall(variants.resolve, "pkg.c", f, path))
  os.execute("rm -rf '" .. dir .. "'")
end)

print(passed .. " cases passed on " .. (jit and jit.version or _VERSION))
