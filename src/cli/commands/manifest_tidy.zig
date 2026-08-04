const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const ManifestTidyCommand = struct {
    pub const name = "tidy";
    pub const description = "Lexicographically tidy source-preserved manifest domains";

    check: bool = false,
    json: bool = false,

    pub fn printHelp(writer: *std.Io.Writer) !void {
        try writer.writeAll("Usage: moon manifest tidy [--check] [--json]\n\nReorders supported manifest domains without reconstructing untouched source.\nScripts sort lexicographically by default; use [manifest.tidy] to preserve author order\nor disable automatic script tidy after script mutations. Consecutive comment lines\nimmediately preceding a script move with it. Floating comments are preserved and\nreported as unattached by this explicit command.\n");
    }

    pub fn run(self: ManifestTidyCommand, ctx: *router.Context) !void {
        const root = try moonstone.project.discovery.enterRoot(ctx.allocator, ctx.io, ".");
        defer root.deinit(ctx.allocator);
        var loaded = try moonstone.project.manifest_editor.load(ctx.allocator, ctx.io, std.Io.Limit.limited(1024 * 1024));
        defer loaded.deinit(ctx.allocator);
        const comments = try moonstone.project.manifest_tidy.unattachedComments(ctx.allocator, loaded.source);
        defer ctx.allocator.free(comments);
        const tidied = try moonstone.project.manifest_tidy.tidyScripts(ctx.allocator, loaded.source);
        defer ctx.allocator.free(tidied);
        const changed = !std.mem.eql(u8, tidied, loaded.source);
        if (!self.json) for (comments) |comment| {
            try ctx.stderr.print("warning: UnattachedManifestComment at moonstone.toml:{d}; preserving its table position\n", .{comment.line});
        };
        if (self.check and changed) return error.ManifestNotTidy;
        if (changed and !self.check) try moonstone.project.manifest_editor.commitSource(ctx.io, tidied);
        if (self.json) {
            try ctx.stdout.print("{{\"contract\":\"moonstone:manifest-tidy:v1\",\"changed\":{s},\"domains\":[\"scripts\"],\"warnings\":[", .{if (changed) "true" else "false"});
            for (comments, 0..) |comment, index| {
                if (index > 0) try ctx.stdout.writeByte(',');
                try ctx.stdout.print("{{\"code\":\"UnattachedManifestComment\",\"section\":\"scripts\",\"line\":{d}}}", .{comment.line});
            }
            try ctx.stdout.writeAll("]}\n");
        }
    }
};
