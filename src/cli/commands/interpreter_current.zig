const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const InterpreterCurrentCommand = struct {
    pub const name = "current";
    pub const description = "Show currently active Lua interpreter";

    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon interpreter current [flags]
            \\
            \\Show the Lua interpreter currently active for this project.
            \\
            \\Flags:
            \\  --json    Output as JSON
            \\
        , .{});
    }

    pub fn run(self: InterpreterCurrentCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;

        const env_toml_path = ".moonstone/env/env.toml";
        const content = std.Io.Dir.cwd().readFileAlloc(io, env_toml_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) {
                try stdout.print("No interpreter selected for current project. Run 'moon interpreter set <spec>'.\n", .{});
                return;
            }
            return err;
        };
        defer allocator.free(content);

        var parser = moonstone.domain.manifest.toml.Parser(moonstone.domain.manifest.toml.Table).init(allocator);
        defer parser.deinit();
        const res = try parser.parseString(content);
        defer res.deinit();

        const rt = res.value.get("runtime").?.table;
        const r_name = rt.get("name").?.string;
        const version = rt.get("version").?.string;
        const abi = rt.get("abi").?.string;

        if (self.json) {
            try stdout.print("{{\"name\": \"{s}\", \"version\": \"{s}\", \"abi\": \"{s}\"}}\n", .{ r_name, version, abi });
        } else {
            try stdout.print("{s}@{s}\nabi: {s}\npath: .moonstone/env/bin/{s}\n", .{ r_name, version, abi, r_name });
        }
    }
};
