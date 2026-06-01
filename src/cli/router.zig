const std = @import("std");
const command_mod = @import("commands/command.zig");
const context = @import("context.zig");

pub const Context = context.Context;

pub const CommandNode = struct {
    name: []const u8,
    description: []const u8,
    run_fn: ?*const fn (args: []const []const u8, ctx: *Context) anyerror!void = null,
    help_fn: *const fn (node: *const CommandNode, stdout: *std.Io.Writer) anyerror!void,
    complete_fn: ?*const fn (args: []const []const u8, ctx: *Context) anyerror![]const []const u8 = null,
    flags_fn: ?*const fn (allocator: std.mem.Allocator) anyerror![]const []const u8 = null,
    subcommands: []const CommandNode = &.{},

    pub fn group(name: []const u8, description: []const u8, subcommands: []const CommandNode) CommandNode {
        return .{
            .name = name,
            .description = description,
            .subcommands = subcommands,
            .help_fn = struct {
                fn help(node: *const CommandNode, stdout: *std.Io.Writer) anyerror!void {
                    try stdout.print("{s}\n\n", .{node.description});
                    if (node.subcommands.len > 0) {
                        try stdout.print("Commands:\n", .{});
                        for (node.subcommands) |sub| {
                            try stdout.print("  {s: <15} {s}\n", .{ sub.name, sub.description });
                        }
                        if (std.mem.eql(u8, node.name, "moon")) {
                            try stdout.print("\nUse 'moon <command> --help' for more information.\n", .{});
                        } else {
                            try stdout.print("\nUse 'moon {s} <command> --help' for more information.\n", .{node.name});
                        }
                    }
                }
            }.help,
        };
    }

    pub fn from(comptime CmdType: type) CommandNode {
        return .{
            .name = if (@hasDecl(CmdType, "command_name")) CmdType.command_name else CmdType.name,
            .description = CmdType.description,
            .run_fn = struct {
                fn argsWantJson(args: []const []const u8) bool {
                    for (args) |arg| {
                        if (std.mem.eql(u8, arg, "--json")) return true;
                    }
                    return false;
                }

                fn reportAndStop(args: []const []const u8, ctx: *Context, cmd: CmdType, err: anyerror) anyerror!void {
                    const is_json = if (@hasField(CmdType, "json")) cmd.json or argsWantJson(args) else argsWantJson(args);
                    const cmd_name = if (@hasDecl(CmdType, "command_name")) CmdType.command_name else CmdType.name;
                    try command_mod.reportError(ctx.allocator, ctx.io, ctx.stdout, is_json, err, cmd_name, ctx.error_detail);
                    return error.AlreadyReported;
                }

                fn run(args: []const []const u8, ctx: *Context) anyerror!void {
                    var cmd: CmdType = .{};
                    var positionals = std.ArrayList([]const u8).empty;
                    defer positionals.deinit(ctx.allocator);

                    var i: usize = 0;
                    var stop_parsing_flags = false;
                    while (i < args.len) : (i += 1) {
                        const arg = args[i];
                        if (!stop_parsing_flags and std.mem.eql(u8, arg, "--")) {
                            stop_parsing_flags = true;
                            continue;
                        }

                        if (!stop_parsing_flags and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
                            try CmdType.printHelp(ctx.stdout);
                            return;
                        }

                        if (!stop_parsing_flags and std.mem.startsWith(u8, arg, "--")) {
                            const flag_name = arg[2..];
                            var matched = false;

                            inline for (std.meta.fields(CmdType)) |field| {
                                if (!std.mem.eql(u8, field.name, "positionals")) {
                                    const expected_flag = comptime blk: {
                                        var buf: [field.name.len]u8 = undefined;
                                        for (field.name, 0..) |c, j| {
                                            buf[j] = if (c == '_') '-' else c;
                                        }
                                        break :blk buf;
                                    };

                                    if (std.mem.eql(u8, &expected_flag, flag_name)) {
                                        matched = true;
                                        if (field.type == bool) {
                                            @field(cmd, field.name) = true;
                                        } else if (field.type == ?[]const u8) {
                                            i += 1;
                                            if (i >= args.len) {
                                                if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
                                                ctx.error_detail = .{ .missing_argument = .{ .flag = try ctx.allocator.dupe(u8, flag_name) } };
                                                return reportAndStop(args, ctx, cmd, error.MissingArgument);
                                            }
                                            @field(cmd, field.name) = args[i];
                                        }
                                    }
                                }
                            }
                            if (!matched) {
                                const cmd_name = if (@hasDecl(CmdType, "command_name")) CmdType.command_name else CmdType.name;
                                if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
                                ctx.error_detail = .{ .unknown_flag = .{ 
                                    .flag = try ctx.allocator.dupe(u8, flag_name),
                                    .command = try ctx.allocator.dupe(u8, cmd_name),
                                } };
                                return reportAndStop(args, ctx, cmd, error.UnknownFlag);
                            }
                        } else {
                            try positionals.append(ctx.allocator, arg);
                        }
                    }

                    if (@hasField(CmdType, "positionals")) {
                        @field(cmd, "positionals") = try positionals.toOwnedSlice(ctx.allocator);
                    } else if (positionals.items.len > 0) {
                        return reportAndStop(args, ctx, cmd, error.UnexpectedPositionalArgument);
                    }

                    cmd.run(ctx) catch |err| {
                        return reportAndStop(args, ctx, cmd, err);
                    };
                }
            }.run,
            .complete_fn = if (@hasDecl(CmdType, "complete")) struct {
                fn complete(args: []const []const u8, ctx: *Context) anyerror![]const []const u8 {
                    return CmdType.complete(args, ctx);
                }
            }.complete else null,
            .flags_fn = struct {
                fn flags(allocator: std.mem.Allocator) anyerror![]const []const u8 {
                    var list = std.ArrayList([]const u8).empty;
                    inline for (std.meta.fields(CmdType)) |field| {
                        if (!std.mem.eql(u8, field.name, "positionals")) {
                            const flag_name = comptime blk: {
                                var buf: [field.name.len + 2]u8 = undefined;
                                buf[0] = '-';
                                buf[1] = '-';
                                for (field.name, 0..) |c, j| {
                                    buf[j + 2] = if (c == '_') '-' else c;
                                }
                                break :blk buf;
                            };
                            try list.append(allocator, try allocator.dupe(u8, &flag_name));
                        }
                    }
                    return list.toOwnedSlice(allocator);
                }
            }.flags,
            .help_fn = struct {
                fn help(node: *const CommandNode, stdout: *std.Io.Writer) anyerror!void {
                    _ = node;
                    try CmdType.printHelp(stdout);
                }
            }.help,
        };
    }
};

pub fn dispatch(root: CommandNode, args: []const []const u8, ctx: *Context) anyerror!void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        try root.help_fn(&root, ctx.stdout);
        return;
    }

    const target = args[0];
    for (root.subcommands) |sub| {
        if (std.mem.eql(u8, sub.name, target)) {
            if (sub.run_fn) |run| {
                // Leaf node
                return run(args[1..], ctx);
            } else {
                // Group node
                return dispatch(sub, args[1..], ctx);
            }
        }
    }

    if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
    ctx.error_detail = .{ .unknown_command = .{ .command = try ctx.allocator.dupe(u8, target) } };
    try command_mod.reportError(ctx.allocator, ctx.io, ctx.stdout, false, error.UnknownCommand, "moon", ctx.error_detail);
    try root.help_fn(&root, ctx.stdout);
    return error.AlreadyReported;
}

pub fn complete(root: *const CommandNode, args: []const []const u8, ctx: *Context) ![]const []const u8 {
    if (args.len == 0) {
        var list = std.ArrayList([]const u8).empty;
        for (root.subcommands) |sub| {
            try list.append(ctx.allocator, sub.name);
        }
        return list.toOwnedSlice(ctx.allocator);
    }

    const target = args[0];

    // If we are at the last argument...
    if (args.len == 1) {
        var list = std.ArrayList([]const u8).empty;
        
        // 1. Check subcommand prefixes
        for (root.subcommands) |sub| {
            if (std.mem.startsWith(u8, sub.name, target)) {
                try list.append(ctx.allocator, sub.name);
            }
        }
        
        // 2. Check flag prefixes (if this node is a leaf or group?)
        // Groups usually don't have flags in our current impl, only leaves.
        if (root.flags_fn) |f_fn| {
            const flags = try f_fn(ctx.allocator);
            defer ctx.allocator.free(flags);
            for (flags) |f| {
                if (std.mem.startsWith(u8, f, target)) {
                    try list.append(ctx.allocator, try ctx.allocator.dupe(u8, f));
                }
            }
        }

        if (list.items.len > 0) return list.toOwnedSlice(ctx.allocator);
    }

    // Try to descend into subcommands
    for (root.subcommands) |sub| {
        if (std.mem.eql(u8, sub.name, target)) {
            if (sub.run_fn != null) {
                // Leaf node: combine its complete_fn suggestions with its flags
                var combined = std.ArrayList([]const u8).empty;
                
                // Add flags
                if (sub.flags_fn) |f_fn| {
                    const flags = try f_fn(ctx.allocator);
                    const last_arg = args[args.len - 1];
                    for (flags) |f| {
                        // Avoid suggesting flags already provided earlier
                        var already_used = false;
                        for (args[0..args.len - 1]) |prev_arg| {
                            if (std.mem.eql(u8, prev_arg, f)) {
                                already_used = true;
                                break;
                            }
                        }

                        if (!already_used and std.mem.startsWith(u8, f, last_arg)) {
                            try combined.append(ctx.allocator, f);
                        } else {
                            ctx.allocator.free(f);
                        }
                    }
                    ctx.allocator.free(flags);
                }

                // Add dynamic completions
                if (sub.complete_fn) |c_fn| {
                    const comps = try c_fn(args[1..], ctx);
                    try combined.appendSlice(ctx.allocator, comps);
                }
                
                return combined.toOwnedSlice(ctx.allocator);
            } else {
                // Group node: recurse
                return complete(&sub, args[1..], ctx);
            }
        }
    }

    return &. {};
}
