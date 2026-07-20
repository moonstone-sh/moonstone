const std = @import("std");
const router = @import("../router.zig");
const SelfInstallCommand = @import("self_install.zig").SelfInstallCommand;

pub const InstallDeprecatedCommand = struct {
    pub const name = "install";
    pub const description = "Install a Moonstone release (deprecated; use 'moon self install')";

    version: ?[]const u8 = null,
    latest: bool = false,
    apply: bool = false,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print("warning: 'moon install' is deprecated. Use 'moon self install' instead.\n\n", .{});
        try SelfInstallCommand.printHelp(stdout);
    }

    pub fn run(self: InstallDeprecatedCommand, ctx: *router.Context) !void {
        if (!self.json) {
            try ctx.stderr.print("warning: 'moon install' is deprecated. Use 'moon self install' instead.\n", .{});
        }
        const self_cmd = SelfInstallCommand{
            .version = self.version,
            .latest = self.latest,
            .apply = self.apply,
            .json = self.json,
        };
        try self_cmd.run(ctx);
    }
};
