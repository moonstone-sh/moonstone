const std = @import("std");
const router = @import("../router.zig");
const SelfUninstallCommand = @import("self_uninstall.zig").SelfUninstallCommand;

pub const UninstallDeprecatedCommand = struct {
    pub const name = "uninstall";
    pub const description = "Remove Moonstone installation/user state (deprecated; use 'moon self uninstall')";

    yes: bool = false,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print("warning: 'moon uninstall' is deprecated. Use 'moon self uninstall' instead.\n\n", .{});
        try SelfUninstallCommand.printHelp(stdout);
    }

    pub fn run(self: UninstallDeprecatedCommand, ctx: *router.Context) !void {
        if (!self.json) {
            try ctx.stderr.print("warning: 'moon uninstall' is deprecated. Use 'moon self uninstall' instead.\n", .{});
        }
        const self_cmd = SelfUninstallCommand{
            .yes = self.yes,
            .json = self.json,
        };
        try self_cmd.run(ctx);
    }
};
