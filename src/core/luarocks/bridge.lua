-- bridge.lua
-- Decoupled Rockspec Parser for Moonstone
-- Evaluates a rockspec in a sandbox and outputs JSON

local rockspec_path = arg[1]
if not rockspec_path then
    io.stderr:write("Usage: lua bridge.lua <path_to_rockspec>\n")
    os.exit(1)
end

-- 1. JSON encoder
--
-- Rockspecs are Lua source, but their domain values are declarative tables.
-- Keep the evaluated document intact rather than selecting only the fields the
-- current materializer understands. In particular, Lua's %q escaping is not
-- JSON escaping: multiline patches can otherwise produce invalid JSON.
local function json_string(value)
    local parts = { '"' }
    for index = 1, #value do
        local byte = string.byte(value, index)
        if byte == 34 then
            parts[#parts + 1] = '\\"'
        elseif byte == 92 then
            parts[#parts + 1] = '\\\\'
        elseif byte == 8 then
            parts[#parts + 1] = '\\b'
        elseif byte == 9 then
            parts[#parts + 1] = '\\t'
        elseif byte == 10 then
            parts[#parts + 1] = '\\n'
        elseif byte == 12 then
            parts[#parts + 1] = '\\f'
        elseif byte == 13 then
            parts[#parts + 1] = '\\r'
        elseif byte < 32 then
            parts[#parts + 1] = string.format('\\u%04x', byte)
        else
            parts[#parts + 1] = string.char(byte)
        end
    end
    parts[#parts + 1] = '"'
    return table.concat(parts)
end

local function dense_array_length(value)
    local count = 0
    local maximum = 0
    for key, _ in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return nil
        end
        count = count + 1
        if key > maximum then
            maximum = key
        end
    end

    if count == maximum then
        return maximum
    end
    return nil
end

local function json_encode(value, seen)
    local value_type = type(value)
    if value_type == "string" then
        return json_string(value)
    elseif value_type == "boolean" then
        return value and "true" or "false"
    elseif value_type == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            error("rockspec contains a non-finite number")
        end
        return tostring(value)
    elseif value_type == "table" then
        seen = seen or {}
        if seen[value] then
            error("rockspec contains a cyclic table")
        end
        seen[value] = true

        local array_length = dense_array_length(value)
        local encoded
        if array_length then
            local parts = {}
            for index = 1, array_length do
                parts[#parts + 1] = json_encode(value[index], seen)
            end
            encoded = "[" .. table.concat(parts, ",") .. "]"
        else
            local entries = {}
            for key, entry_value in pairs(value) do
                local key_type = type(key)
                if key_type ~= "string" and key_type ~= "number" then
                    error("rockspec table has a non-string, non-number key")
                end
                entries[#entries + 1] = {
                    key = tostring(key),
                    value = entry_value,
                }
            end
            table.sort(entries, function(left, right)
                return left.key < right.key
            end)

            local parts = {}
            for _, entry in ipairs(entries) do
                parts[#parts + 1] = json_string(entry.key) .. ":" .. json_encode(entry.value, seen)
            end
            encoded = "{" .. table.concat(parts, ",") .. "}"
        end

        seen[value] = nil
        return encoded
    elseif value_type == "nil" then
        return "null"
    end

    error("rockspec contains a non-data value of type " .. value_type)
end

-- 2. Sandbox Setup
--
-- Use a proxy environment so rockspec declarations named `package`, `table`,
-- or another standard global cannot overwrite the sandbox helpers before we
-- collect them. A rockspec's assignments always land in declared_globals.
local standard_env = {
    assert = assert,
    error = error,
    pcall = pcall,
    select = select,
    pairs = pairs,
    ipairs = ipairs,
    next = next,
    tostring = tostring,
    tonumber = tonumber,
    type = type,
    string = string,
    table = table,
    math = math,
    os = { getenv = os.getenv },
    package = { config = package.config },
    jit = jit,
    _VERSION = _VERSION,
}

-- Mock LuaRocks global function used in some rockspecs.
function standard_env.print(...) end

local declared_globals = {}
local env = setmetatable({}, {
    __index = function(_, key)
        local declared = declared_globals[key]
        if declared ~= nil then
            return declared
        end
        return standard_env[key]
    end,
    __newindex = function(_, key, value)
        declared_globals[key] = value
    end,
})

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

-- If the rockspec didn't return a table, it usually defines globals. Keep only
-- declarations introduced by that source; the sandbox's standard-library
-- helpers are not part of the rockspec document.
local final_data
if type(res) == "table" then
    final_data = res
else
    final_data = declared_globals
end

local supported_rockspec_formats = {
    ["1.0"] = true,
    ["1.1"] = true,
    ["3.0"] = true,
    ["3.1"] = true,
}

local rockspec_format = final_data.rockspec_format or "1.0"
if type(rockspec_format) ~= "string" or not supported_rockspec_formats[rockspec_format] then
    io.stderr:write("error: [UnsupportedRockspecFormat] Moonstone supports rockspec formats 1.0, 1.1, 3.0, and 3.1; found " .. tostring(rockspec_format) .. "\n")
    os.exit(1)
end

local function schema_error(path, message)
    io.stderr:write("error: [InvalidRockspecSchema] " .. path .. ": " .. message .. "\n")
    os.exit(1)
end

local function expect_type(value, expected, path)
    if type(value) ~= expected then
        schema_error(path, "expected " .. expected)
    end
end

local function check_string_array(value, path)
    expect_type(value, "table", path)
    for key, item in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            schema_error(path, "expected an array")
        end
        expect_type(item, "string", path .. "[" .. key .. "]")
    end
end

local function check_no_unknown(value, allowed, path)
    for key, _ in pairs(value) do
        if not allowed[key] then
            schema_error(path .. "." .. tostring(key), "is not supported by rockspec format " .. rockspec_format)
        end
    end
end

local function check_platform_overrides(value, path, check)
    if value.platforms == nil then return end
    expect_type(value.platforms, "table", path .. ".platforms")
    for platform, override in pairs(value.platforms) do
        expect_type(platform, "string", path .. ".platforms key")
        expect_type(override, "table", path .. ".platforms." .. platform)
        check(override, path .. ".platforms." .. platform, true)
    end
end

local function check_description(value, path)
    expect_type(value, "table", path)
    local allowed = {
        summary = true, detailed = true, homepage = true, license = true,
        maintainer = true,
    }
    if rockspec_format == "3.0" or rockspec_format == "3.1" then
        allowed.labels = true
        allowed.issues_url = true
    end
    check_no_unknown(value, allowed, path)
    for key, item in pairs(value) do
        if key == "labels" then
            expect_type(item, "table", path .. ".labels")
        else
            expect_type(item, "string", path .. "." .. key)
        end
    end
end

local source_fields = {
    url = true, md5 = true, file = true, dir = true, tag = true, branch = true,
    module = true, cvs_tag = true, cvs_module = true, platforms = true,
}
local function check_source(value, path, platform_override)
    expect_type(value, "table", path)
    check_no_unknown(value, source_fields, path)
    if not platform_override and value.url == nil then
        schema_error(path .. ".url", "is required")
    end
    for key, item in pairs(value) do
        if key ~= "platforms" then
            expect_type(item, "string", path .. "." .. key)
        end
    end
    check_platform_overrides(value, path, check_source)
end

local function check_dependency_list(value, path, platform_override)
    expect_type(value, "table", path)
    local dependency_pattern
    if rockspec_format == "1.0" or rockspec_format == "1.1" then
        dependency_pattern = "%s*([a-zA-Z0-9][a-zA-Z0-9%.%-%_]*)%s*([^/]*)"
    else
        dependency_pattern = "%s*([a-zA-Z0-9%.%-%_]*/?[a-zA-Z0-9][a-zA-Z0-9%.%-%_]*)%s*([^/]*)"
    end
    for key, item in pairs(value) do
        if key == "platforms" then
            -- checked below
        elseif type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            schema_error(path .. "." .. tostring(key), "expected a dependency array entry")
        else
            expect_type(item, "string", path .. "[" .. key .. "]")
            if not item:match("^" .. dependency_pattern .. "$") then
                schema_error(path .. "[" .. key .. "]", "is not a valid dependency string")
            end
        end
    end
    check_platform_overrides(value, path, check_dependency_list)
end

local external_dependency_fields = { program = true, header = true, library = true }
local function check_external_dependencies(value, path, platform_override)
    expect_type(value, "table", path)
    for key, item in pairs(value) do
        if key ~= "platforms" then
            expect_type(key, "string", path .. " key")
            expect_type(item, "table", path .. "." .. key)
            check_no_unknown(item, external_dependency_fields, path .. "." .. key)
            for field, field_value in pairs(item) do
                expect_type(field_value, "string", path .. "." .. key .. "." .. field)
            end
        end
    end
    check_platform_overrides(value, path, check_external_dependencies)
end

local function check_install(value, path)
    expect_type(value, "table", path)
    check_no_unknown(value, { lua = true, lib = true, conf = true, bin = true }, path)
    for kind, files in pairs(value) do
        expect_type(files, "table", path .. "." .. kind)
    end
end

local function check_string_map(value, path)
    expect_type(value, "table", path)
    for key, item in pairs(value) do
        expect_type(key, "string", path .. " key")
        expect_type(item, "string", path .. "." .. key)
    end
end

local function check_build(value, path, platform_override)
    expect_type(value, "table", path)
    if value.type ~= nil then expect_type(value.type, "string", path .. ".type") end
    if value.build_command ~= nil then expect_type(value.build_command, "string", path .. ".build_command") end
    if value.install_command ~= nil then expect_type(value.install_command, "string", path .. ".install_command") end
    if value.variables ~= nil then check_string_map(value.variables, path .. ".variables") end
    if value.makefile ~= nil then expect_type(value.makefile, "string", path .. ".makefile") end
    if value.build_target ~= nil then expect_type(value.build_target, "string", path .. ".build_target") end
    if value.install_target ~= nil then expect_type(value.install_target, "string", path .. ".install_target") end
    if value.build_variables ~= nil then check_string_map(value.build_variables, path .. ".build_variables") end
    if value.install_variables ~= nil then check_string_map(value.install_variables, path .. ".install_variables") end
    if value.install ~= nil then check_install(value.install, path .. ".install") end
    if value.copy_directories ~= nil then check_string_array(value.copy_directories, path .. ".copy_directories") end
    if value.patches ~= nil then check_string_map(value.patches, path .. ".patches") end
    check_platform_overrides(value, path, check_build)
end

local function check_test(value, path, platform_override)
    expect_type(value, "table", path)
    if value.type ~= nil then expect_type(value.type, "string", path .. ".type") end
    check_platform_overrides(value, path, check_test)
end

local function check_hooks(value, path, platform_override)
    expect_type(value, "table", path)
    check_no_unknown(value, { post_install = true, platforms = true }, path)
    if value.post_install ~= nil then expect_type(value.post_install, "string", path .. ".post_install") end
    check_platform_overrides(value, path, check_hooks)
end

local root_fields = {
    rockspec_format = true, package = true, version = true, description = true,
    dependencies = true, supported_platforms = true, external_dependencies = true,
    source = true, build = true, hooks = true,
}
if rockspec_format == "1.1" or rockspec_format == "3.0" or rockspec_format == "3.1" then
    root_fields.deploy = true
end
if rockspec_format == "3.0" or rockspec_format == "3.1" then
    root_fields.build_dependencies = true
    root_fields.test_dependencies = true
    root_fields.test = true
end

expect_type(final_data, "table", "rockspec")
check_no_unknown(final_data, root_fields, "rockspec")
if final_data.package == nil then schema_error("rockspec.package", "is required") end
if final_data.version == nil then schema_error("rockspec.version", "is required") end
if final_data.source == nil then schema_error("rockspec.source", "is required") end
if rockspec_format == "1.0" or rockspec_format == "1.1" then
    if final_data.build == nil then schema_error("rockspec.build", "is required by rockspec format " .. rockspec_format) end
end
expect_type(final_data.package, "string", "rockspec.package")
expect_type(final_data.version, "string", "rockspec.version")
if not final_data.version:match("^[%w%.]+%-%d+$") then
    schema_error("rockspec.version", "is not a valid rock version")
end
check_source(final_data.source, "rockspec.source", false)
if final_data.description ~= nil then check_description(final_data.description, "rockspec.description") end
if final_data.dependencies ~= nil then check_dependency_list(final_data.dependencies, "rockspec.dependencies") end
if final_data.build_dependencies ~= nil then check_dependency_list(final_data.build_dependencies, "rockspec.build_dependencies") end
if final_data.test_dependencies ~= nil then check_dependency_list(final_data.test_dependencies, "rockspec.test_dependencies") end
if final_data.supported_platforms ~= nil then check_string_array(final_data.supported_platforms, "rockspec.supported_platforms") end
if final_data.external_dependencies ~= nil then check_external_dependencies(final_data.external_dependencies, "rockspec.external_dependencies") end
if final_data.build ~= nil then check_build(final_data.build, "rockspec.build") end
if final_data.test ~= nil then check_test(final_data.test, "rockspec.test") end
if final_data.hooks ~= nil then check_hooks(final_data.hooks, "rockspec.hooks") end
if final_data.deploy ~= nil then
    expect_type(final_data.deploy, "table", "rockspec.deploy")
    check_no_unknown(final_data.deploy, { wrap_bin_scripts = true }, "rockspec.deploy")
    if final_data.deploy.wrap_bin_scripts ~= nil then expect_type(final_data.deploy.wrap_bin_scripts, "boolean", "rockspec.deploy.wrap_bin_scripts") end
end

-- 4. Clean and Normalize for JSON
-- We only care about fields used by Moonstone
local function current_platform()
    local forced = arg[2] or os.getenv("MOONSTONE_LUAROCKS_PLATFORM")
    if forced and forced ~= "" then return forced end
    if jit and jit.os == "OSX" then return "macosx" end
    if jit and jit.os == "Windows" then return "win32" end
    if jit and jit.os == "Linux" then return "linux" end
    if package.config:sub(1, 1) == "\\" then return "win32" end
    return "unix"
end

local function platform_order(platform)
    if platform == "win32" or platform == "mingw32" then
        return { "windows", "win32", platform }
    elseif platform == "linux" then
        return { "unix", "linux" }
    elseif platform == "macosx" then
        return { "unix", "macosx" }
    elseif platform == "freebsd" then
        return { "unix", "bsd", "freebsd" }
    elseif platform == "openbsd" then
        return { "unix", "bsd", "openbsd" }
    elseif platform == "netbsd" then
        return { "unix", "bsd", "netbsd" }
    elseif platform == "dragonfly" then
        return { "unix", "bsd", "dragonfly" }
    elseif platform == "solaris" then
        return { "unix", "solaris" }
    elseif platform == "cygwin" or platform == "msys" then
        return { "unix", platform }
    end
    return { platform }
end

local function copy_table(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        error("rockspec contains a cyclic table")
    end
    seen[value] = true

    local copy = {}
    for key, entry_value in pairs(value) do
        copy[key] = copy_table(entry_value, seen)
    end
    seen[value] = nil
    return copy
end

local function deep_merge(target, override)
    for key, value in pairs(override) do
        if type(value) == "table" and type(target[key]) == "table" then
            deep_merge(target[key], value)
        elseif type(value) == "table" then
            target[key] = copy_table(value)
        else
            target[key] = value
        end
    end
end

local function platform_projection(value, platform)
    local projected = copy_table(value)
    if type(projected) ~= "table" then
        return projected
    end

    local platforms = projected.platforms
    if type(platforms) == "table" then
        for _, selector in ipairs(platform_order(platform)) do
            local override = platforms[selector]
            if type(override) == "table" then
                deep_merge(projected, override)
            end
        end
    end
    projected.platforms = nil
    return projected
end

local function normalize_source(value)
    if type(value) ~= "table" then
        return value
    end
    if value.cvs_module ~= nil then
        value.module = value.cvs_module
    end
    if value.cvs_tag ~= nil then
        value.tag = value.cvs_tag
    end
    if value.dir == nil then
        value.dir = value.module
    end
    return value
end

local selected_platform = current_platform()
local semantic_source = normalize_source(platform_projection(final_data.source, selected_platform))
local semantic_build = platform_projection(final_data.build, selected_platform)
if semantic_build == nil then
    -- Rockspec format 3.0 permits omitting build. The raw document preserves
    -- that distinction; the legacy resolver projection uses an empty table so
    -- its omitted-type default remains `builtin`.
    semantic_build = {}
end
if type(semantic_build) == "table" and (semantic_build.type == nil or semantic_build.type == "") then
    semantic_build.type = "builtin"
end

local semantic_dependencies = platform_projection(final_data.dependencies, selected_platform)
local semantic_build_dependencies = platform_projection(final_data.build_dependencies, selected_platform)
local semantic_test_dependencies = platform_projection(final_data.test_dependencies, selected_platform)
local semantic_external_dependencies = platform_projection(final_data.external_dependencies, selected_platform)
local semantic_hooks = platform_projection(final_data.hooks, selected_platform)
local semantic_test = platform_projection(final_data.test, selected_platform)

local function declaration_array(value)
    if type(value) ~= "table" then
        return value
    end

    local indexes = {}
    for key, _ in pairs(value) do
        if type(key) == "number" and key >= 1 and key % 1 == 0 then
            indexes[#indexes + 1] = key
        end
    end
    table.sort(indexes)

    local entries = {}
    for _, index in ipairs(indexes) do
        entries[#entries + 1] = value[index]
    end
    return entries
end

local normalized = {
    -- The complete evaluated declaration is the parsing contract. Consumers
    -- needing a materialization recipe must read the normalized fields below.
    document = final_data,
    validation = {
        schema = "moonstone:luarocks-validation:v1",
        rockspec_format = rockspec_format,
        valid = true,
    },
    intent = {
        schema = "moonstone:luarocks-intent:v1",
        platform = selected_platform,
        rockspec_format = rockspec_format,
        source = semantic_source,
        dependencies = declaration_array(semantic_dependencies) or {},
        supported_platforms = declaration_array(final_data.supported_platforms) or {},
        build_dependencies = declaration_array(semantic_build_dependencies) or {},
        test_dependencies = declaration_array(semantic_test_dependencies) or {},
        external_dependencies = semantic_external_dependencies,
        build = semantic_build,
        build_declaration = semantic_build,
        hooks = semantic_hooks,
        test = semantic_test,
    },
    package = final_data.package,
    version = final_data.version,
    source = semantic_source,
    build = semantic_build,
    -- LuaRocks allows dependency arrays to carry a sibling `platforms` map.
    -- The complete map remains in document; intent.dependencies is the
    -- platform-selected list consumed by Moonstone resolution.
    dependencies = declaration_array(semantic_dependencies),
    external_dependencies = semantic_external_dependencies,
}

io.write(json_encode(normalized))
os.exit(0)
