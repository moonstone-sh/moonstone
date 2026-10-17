const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");

pub const StoreListCommand = struct {
    pub const name = "list";
    pub const description = "List content in the local store or link registry";

    links: bool = false,
    interpreters: bool = false,
    json: bool = false,
    query: ?[]const u8 = null,
    by_artifact_hash: ?[]const u8 = null,
    by_source_hash: ?[]const u8 = null,
    by_package: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    resolver: ?[]const u8 = null,
    target: ?[]const u8 = null,
    abi: ?[]const u8 = null,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon store list [flags]
            \\
            \\List content currently installed or registered in Moonstone.
            \\
            \\Flags:
            \\  --links     List globally registered local links
            \\  --interpreters List installed Lua interpreters
            \\  --query <q> Fuzzy package name search
            \\  --by-artifact-hash <hash> Match an exact artifact hash
            \\  --by-source-hash <hash> Match an exact source hash
            \\  --by-package <name> Match an exact package name
            \\  --kind <k>  Filter by kind (lib, bin, runtime)
            \\  --resolver <r> Filter by resolver (moonstone, rocks)
            \\  --target <t> Filter by target triple
            \\  --abi <abi> Filter by Lua ABI
            \\  --json      Emit newline-delimited JSON events
            \\
        , .{});
    }

    pub fn run(self: StoreListCommand, ctx: *router.Context) !void {
        if (self.links) {
            if (self.interpreters or self.query != null or self.by_artifact_hash != null or self.by_source_hash != null or self.by_package != null or self.kind != null or self.resolver != null or self.target != null or self.abi != null) return error.IncompatibleStoreFilters;
            return self.runLinks(ctx);
        }
        if (self.interpreters and self.kind != null) return error.IncompatibleStoreFilters;
        return (@import("store_query.zig").StoreQueryCommand{
            .by_name = self.query,
            .by_artifact_hash = self.by_artifact_hash,
            .by_source_hash = self.by_source_hash,
            .by_package = self.by_package,
            .kind = if (self.interpreters) "runtime" else self.kind,
            .resolver = self.resolver,
            .target = self.target,
            .abi = self.abi,
            .json = self.json,
        }).run(ctx);
    }

    fn runLinks(self: StoreListCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        var emitter_obj = if (self.json) ndjson.Emitter.init(allocator, stdout, "links-list") else null;
        const emitter = if (emitter_obj) |*e| e else null;

        if (emitter) |e| {
            try e.emit(io, .START, "links-list", "begin", .{});
        }

        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer {
            var p = paths;
            p.deinit(allocator);
        }

        try std.Io.Dir.cwd().createDirPath(io, paths.index);
        const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
        defer allocator.free(index_db_path);
        const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
        defer allocator.free(index_db_path_z);

        var idx = try moonstone.store.driver.StoreDriver.init(allocator, index_db_path_z);
        defer idx.deinit();

        const lr = moonstone.store.links.LinkStore.init(&idx);
        const entries = try lr.list();
        defer {
            for (entries) |*e| e.deinit(allocator);
            allocator.free(entries);
        }

        if (emitter == null) {
            try stdout.print("{s: <20} {s: <10} {s}\n", .{ "Name", "Version", "Path" });
            try stdout.print("--------------------------------------------------------------------------------\n", .{});
        }

        for (entries) |entry| {
            if (emitter) |e| {
                try e.emit(io, .STATUS, entry.name, "link", .{
                    .name = entry.name,
                    .version = entry.version,
                    .path = entry.path,
                    .kind = entry.kind,
                });
            } else {
                try stdout.print("{s: <20} {s: <10} {s}\n", .{ entry.name, entry.version, entry.path });
            }
        }

        if (emitter) |e| {
            try e.terminate(io, "links-list", "ok", .{ .count = entries.len });
        } else if (entries.len == 0) {
            try stdout.print("(no registered links found)\n", .{});
        }
    }
};
