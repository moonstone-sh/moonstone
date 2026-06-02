-- bridge.lua
-- Decoupled Rockspec Parser for Moonstone
-- Evaluates a rockspec in a sandbox and outputs JSON

local rockspec_path = arg[1]
if not rockspec_path then
    io.stderr:write("Usage: lua bridge.lua <path_to_rockspec>\n")
    os.exit(1)
end

-- 1. Minimal JSON Encoder
local function json_encode(v)
    if type(v) == "string" then
        return string.format("%q", v):gsub("\n", "n"):gsub("\r", "r")
    elseif type(v) == "number" or type(v) == "boolean" then
        return tostring(v)
    elseif type(v) == "table" then
        local is_array = true
        local n = 0
        for k, _ in pairs(v) do
            n = n + 1
            if type(k) ~= "number" or k ~= n then
                is_array = false
                break
            end
        end

        if is_array then
            local parts = {}
            for i = 1, n do
                parts[#parts + 1] = json_encode(v[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, val in pairs(v) do
                if type(k) == "string" then
                    parts[#parts + 1] = string.format("%q", k) .. ":" .. json_encode(val)
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    else
        return "null"
    end
end

-- 2. Sandbox Setup
local env = {
    pairs = pairs,
    ipairs = ipairs,
    next = next,
    tostring = tostring,
    tonumber = tonumber,
    type = type,
    string = string,
    table = table,
    math = table,
    os = { getenv = os.getenv },
    package = { config = package.config },
    jit = jit,
    _VERSION = _VERSION,
}

-- Mock LuaRocks global functions used in some rockspecs
function env.print(...) end
function env.error(msg) io.stderr:write(msg .. "\n") os.exit(1) end

-- 3. Load and Evaluate
local chunk, err
if _VERSION == "Lua 5.1" then
    chunk, err = loadfile(rockspec_path)
    if chunk then setfenv(chunk, env) end
else
    chunk, err = loadfile(rockspec_path, "t", env)
end

if not chunk then
    io.stderr:write("Error loading rockspec: " .. tostring(err) .. "\n")
    os.exit(1)
end

-- Run it
local ok, res = pcall(chunk)
if not ok then
    io.stderr:write("Error evaluating rockspec: " .. tostring(res) .. "\n")
    os.exit(1)
end

-- If the rockspec didn't return a table, it usually defines globals
local final_data = type(res) == "table" and res or env

-- 4. Clean and Normalize for JSON
-- We only care about fields used by Moonstone
local function current_platform()
    local forced = arg[2] or os.getenv("MOONSTONE_LUAROCKS_PLATFORM")
    if forced and forced ~= "" then return forced end
    if jit and jit.os == "OSX" then return "macosx" end
    if jit and jit.os == "Windows" then return "win32" end
    if package.config:sub(1, 1) == "\\" then return "win32" end
    return "unix"
end

if type(final_data.build) == "table" and final_data.build.modules == nil and type(final_data.build.platforms) == "table" then
    local platform_build = final_data.build.platforms[current_platform()]
    if type(platform_build) == "table" then
        final_data.build.modules = platform_build.modules
        final_data.build.install = final_data.build.install or platform_build.install
    end
end

local normalized = {
    package = final_data.package,
    version = final_data.version,
    source = final_data.source,
    build = final_data.build,
    dependencies = final_data.dependencies,
    external_dependencies = final_data.external_dependencies,
}

io.write(json_encode(normalized))
os.exit(0)
