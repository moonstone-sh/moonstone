const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const LinkCommand = struct {
    pub const name = "link";
    pub const description = "Register current project in the global link store";

    positionals: []const []const u8 = &.{},
    force: bool = false,
    p_name: ?[]const u8 = null,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon link [flags]
            \\
            \\Register the current project in the global link store.
            \\Consume registered links with `moon add link:<name>`.
            \\
            \\Flags:
            \\  --name <name>          Override package name
            \\  --force                Overwrite existing registration
            \\  --json                 Machine-readable output
            \\
        , .{});
    }

    pub fn run(self: LinkCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        if (self.positionals.len != 0) return error.UnexpectedArgument;

        try registerCurrentProject(self, allocator, io, stdout, env);
    }
};

fn registerCurrentProject(self: LinkCommand, allocator: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, env: *std.process.Environ.Map) !void {
    const toml_content = try std.Io.Dir.cwd().readFileAlloc(io, "moonstone.toml", allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(toml_content);

    var mt = try moonstone.domain.manifest.MoonstoneToml.parse(allocator, toml_content);
    defer mt.deinit(allocator);

    const pkg_name = self.p_name orelse mt.package.name;
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
    defer { var p = paths; p.deinit(allocator); }

    try std.Io.Dir.cwd().createDirPath(io, paths.index);

    const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
    defer allocator.free(index_db_path);
    const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
    defer allocator.free(index_db_path_z);

    var idx = try moonstone.store.driver.StoreDriver.init(allocator, index_db_path_z);
    defer idx.deinit();

    var lr = moonstone.store.links.LinkStore.init(&idx);

    if (!self.force) {
        if (try lr.get(pkg_name)) |existing| {
            var mut_existing = existing;
            mut_existing.deinit(allocator);
            return error.AlreadyRegistered;
        }
    }

    try lr.register(.{
        .name = pkg_name,
        .path = cwd,
        .mode = .live,
        .version = mt.package.version,
        .kind = mt.package.kind,
    });


    if (!self.json) {
        try stdout.print("Linked package registered: {s} -> {s}\n", .{ pkg_name, cwd });
    }
}
