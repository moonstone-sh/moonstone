const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

/// Minimal machine-facing adapter for callers such as Ballad. The core API is
/// intentionally the authority for validation and artifact construction.
pub const ArtifactCreateCommand = struct {
    pub const name = "create";
    pub const description = "Create a canonical .tar.gz artifact from declared files";

    out: ?[]const u8 = null,
    json: bool = false,
    entries_file: ?[]const u8 = null,
    positionals: []const []const u8 = &.{},

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon artifact create --out <artifact.tar.gz> --json -- <virtual-path> <source-path> <mode> [...]
            \\
            \\Create a canonical gzip-compressed tar artifact. Each entry is an
            \\explicit triple: archive virtual path, source regular-file path, and
            \\portable mode (0644 or 0755). Entries are sorted by virtual path.
            \\Source directories, symlinks, and special files are rejected.
            \\
            \\Success JSON contract (moonstone:artifact-create:v1):
            \\  {{"contract":"moonstone:artifact-create:v1","path":"...","bytes":0,"b3":"b3:<hex>"}}
            \\
            \\Flags:
            \\  --out <path>  Destination file; its parent directory must exist
            \\  --entries-file <path> JSON moonstone:artifact-entries:v1 document; replaces triples
            \\  --json        Required. Emit the machine-facing result object
            \\
        , .{});
    }

    pub fn run(self: ArtifactCreateCommand, ctx: *router.Context) !void {
        if (!self.json) return error.ArtifactJsonRequired;
        const output_path = self.out orelse return error.MissingArtifactOutput;
        if (self.positionals.len % 3 != 0) return error.InvalidArtifactEntryArguments;

        var entries = std.ArrayList(moonstone.archive.canonical_artifact.Entry).empty;
        defer entries.deinit(ctx.allocator);
        const EntryDocument = struct {
            contract: []const u8,
            entries: []const struct { virtual_path: []const u8, source_path: []const u8, mode: []const u8 },
        };
        const source = if (self.entries_file) |file| try std.Io.Dir.cwd().readFileAlloc(ctx.io, file, ctx.allocator, .limited(16 * 1024 * 1024)) else null;
        defer if (source) |bytes| ctx.allocator.free(bytes);
        const document = if (source) |bytes| try std.json.parseFromSlice(EntryDocument, ctx.allocator, bytes, .{}) else null;
        defer if (document) |parsed| parsed.deinit();
        if (document) |parsed| {
            if (self.positionals.len != 0) return error.MixedArtifactEntryArguments;
            if (!std.mem.eql(u8, parsed.value.contract, "moonstone:artifact-entries:v1")) return error.InvalidArtifactEntriesContract;
            for (parsed.value.entries) |entry| try entries.append(ctx.allocator, .{
                .virtual_path = entry.virtual_path,
                .source_path = entry.source_path,
                .mode = try moonstone.archive.canonical_artifact.PortableMode.parse(entry.mode),
            });
        }
        var index: usize = 0;
        while (index < self.positionals.len) : (index += 3) {
            try entries.append(ctx.allocator, .{
                .virtual_path = self.positionals[index],
                .source_path = self.positionals[index + 1],
                .mode = try moonstone.archive.canonical_artifact.PortableMode.parse(self.positionals[index + 2]),
            });
        }

        var result = try moonstone.archive.canonical_artifact.create(ctx.allocator, ctx.io, output_path, entries.items);
        defer result.deinit(ctx.allocator);
        try std.json.Stringify.value(.{
            .contract = "moonstone:artifact-create:v1",
            .path = result.path,
            .bytes = result.bytes,
            .b3 = result.b3,
        }, .{}, ctx.stdout);
        try ctx.stdout.writeAll("\n");
    }
};
