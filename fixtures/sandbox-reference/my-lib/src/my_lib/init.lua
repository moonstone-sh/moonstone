local my_lib = {}

--- Define special sequences of characters.
-- For each pair (find, subs), the function will create a field named with
-- find which has the value of subs.
-- It also creates an index for the table, according to the order of insertion.
-- @param name The pattern to find.
function my_lib.greet(name)
	return "Hello, " .. (name or "world") .. "!"
end

---@class BuildOptions
---@field entry string Main input file.
---@field out_dir string Output directory.
---@field minify? boolean Optional minify flag.
---@field target? "lua54"|"luajit"|"love" Optional target runtime.
---@field defines? table<string, string|boolean> Compile-time defines.

---@param opts BuildOptions
---@return boolean ok
---@return string? err
function my_lib.build(opts)
	if opts.entry == "" then
		return false, "missing entry"
	end

	local target = opts.target or "lua54"

	print("building", opts.entry, "for", target)

	if opts.minify then
		print("minifying output")
	end

	return true, nil
end

return my_lib
