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
    fallback_dispatch_fn: ?*const fn (args: []const []const u8, ctx: *Context) anyerror!void = null,
    fallback_complete_fn: ?*const fn (args: []const []const u8, ctx: *Context) anyerror![]const []const u8 = null,
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

    pub fn groupWithFallback(
        name: []const u8,
        description: []const u8,
        subcommands: []const CommandNode,
        fallback_dispatch_fn: *const fn (args: []const []const u8, ctx: *Context) anyerror!void,
        fallback_complete_fn: *const fn (args: []const []const u8, ctx: *Context) anyerror![]const []const u8,
    ) CommandNode {
        var node = group(name, description, subcommands);
        node.fallback_dispatch_fn = fallback_dispatch_fn;
        node.fallback_complete_fn = fallback_complete_fn;
        return node;
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
                    if (@hasField(CmdType, "quiet") and cmd.quiet) return error.AlreadyReported;
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
                    var saw_dashdash = false;
                    // Index (within `args`) of the first token collected as a
                    // positional while `!saw_dashdash`. Once set, any further
                    // token that looks like a flag is almost certainly meant
                    // for the wrapped command (e.g. `-c` in `sh -c '...'`),
                    // not for Moonstone itself.
                    var first_positional_index: ?usize = null;
                    const requires_dashdash: bool = comptime @hasDecl(CmdType, "requires_dashdash") and CmdType.requires_dashdash;
                    while (i < args.len) : (i += 1) {
                        const arg = args[i];
                        // Once opaque forwarding has started (the wrapped command's
                        // name has been consumed), every remaining token — including
                        // any further "--" the wrapped command wants for itself, e.g.
                        // `moon exec -- docker run x -- y` — is forwarded verbatim.
                        // Moonstone's own "--" handling only ever applies BEFORE that
                        // boundary (see the `!stop_parsing_flags` branch below); it
                        // must never re-interpret a "--" that belongs to the child.
                        if (!stop_parsing_flags and std.mem.eql(u8, arg, "--")) {
                            stop_parsing_flags = true;
                            saw_dashdash = true;
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
                                        const suffix = "_arg";
                                        const base_name = if (std.mem.endsWith(u8, field.name, suffix)) field.name[0 .. field.name.len - suffix.len] else field.name;
                                        var buf: [base_name.len]u8 = undefined;
                                        for (base_name, 0..) |c, j| {
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
                                                ctx.error_detail = .{ .missing_argument = .{ .flag = try ctx.allocator.dupe(u8, flag_name), .is_long = true } };
                                                return reportAndStop(args, ctx, cmd, error.MissingArgument);
                                            }
                                            @field(cmd, field.name) = args[i];
                                        }
                                    }
                                }
                            }
                            if (!matched) {
                                if (requires_dashdash and first_positional_index != null) {
                                    const cmd_name = if (@hasDecl(CmdType, "command_name")) CmdType.command_name else CmdType.name;
                                    if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
                                    const suggestion = try buildMissingDashDashSuggestion(ctx.allocator, ctx, args, first_positional_index.?);
                                    ctx.error_detail = .{ .missing_dashdash = .{
                                        .command = try ctx.allocator.dupe(u8, cmd_name),
                                        .suggestion = suggestion,
                                    } };
                                    return reportAndStop(args, ctx, cmd, error.MissingDashDash);
                                }
                                const cmd_name = if (@hasDecl(CmdType, "command_name")) CmdType.command_name else CmdType.name;
                                if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
                                ctx.error_detail = .{ .unknown_flag = .{
                                    .flag = try ctx.allocator.dupe(u8, flag_name),
                                    .command = try ctx.allocator.dupe(u8, cmd_name),
                                    .is_long = true,
                                } };
                                return reportAndStop(args, ctx, cmd, error.UnknownFlag);
                            }
                        } else if (!stop_parsing_flags and std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
                            const short_flag = arg[1..];
                            var matched = false;

                            inline for (std.meta.fields(CmdType)) |field| {
                                if (!std.mem.eql(u8, field.name, "positionals")) {
                                    if (field.name.len > 0 and short_flag.len == 1 and field.name[0] == short_flag[0]) {
                                        matched = true;
                                        if (field.type == bool) {
                                            @field(cmd, field.name) = true;
                                        } else if (field.type == ?[]const u8) {
                                            i += 1;
                                            if (i >= args.len) {
                                                if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
                                                ctx.error_detail = .{ .missing_argument = .{ .flag = try ctx.allocator.dupe(u8, short_flag), .is_long = false } };
                                                return reportAndStop(args, ctx, cmd, error.MissingArgument);
                                            }
                                            @field(cmd, field.name) = args[i];
                                        }
                                    }
                                }
                            }
                            if (!matched) {
                                if (requires_dashdash and first_positional_index != null) {
                                    const cmd_name = if (@hasDecl(CmdType, "command_name")) CmdType.command_name else CmdType.name;
                                    if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
                                    const suggestion = try buildMissingDashDashSuggestion(ctx.allocator, ctx, args, first_positional_index.?);
                                    ctx.error_detail = .{ .missing_dashdash = .{
                                        .command = try ctx.allocator.dupe(u8, cmd_name),
                                        .suggestion = suggestion,
                                    } };
                                    return reportAndStop(args, ctx, cmd, error.MissingDashDash);
                                }
                                const cmd_name = if (@hasDecl(CmdType, "command_name")) CmdType.command_name else CmdType.name;
                                if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
                                ctx.error_detail = .{ .unknown_flag = .{
                                    .flag = try ctx.allocator.dupe(u8, short_flag),
                                    .command = try ctx.allocator.dupe(u8, cmd_name),
                                    .is_long = false,
                                } };
                                return reportAndStop(args, ctx, cmd, error.UnknownFlag);
                            }
                        } else {
                            if (requires_dashdash and !stop_parsing_flags and first_positional_index == null) {
                                first_positional_index = i;
                            }
                            try positionals.append(ctx.allocator, arg);
                        }
                    }

                    if (requires_dashdash and positionals.items.len > 0 and !saw_dashdash) {
                        const cmd_name = if (@hasDecl(CmdType, "command_name")) CmdType.command_name else CmdType.name;
                        if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
                        const suggestion = try buildMissingDashDashSuggestion(ctx.allocator, ctx, args, first_positional_index.?);
                        ctx.error_detail = .{ .missing_dashdash = .{
                            .command = try ctx.allocator.dupe(u8, cmd_name),
                            .suggestion = suggestion,
                        } };
                        return reportAndStop(args, ctx, cmd, error.MissingDashDash);
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

fn isShellSafeArgChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '/', ':', '=', ',', '+', '@' => true,
        else => false,
    };
}

/// Appends `arg` to `out`, single-quoting it (shell-style) when it contains
/// anything a shell would otherwise treat specially. Kept intentionally
/// simple: this only has to produce a sensible, copy-pasteable suggestion,
/// not handle every shell-quoting edge case.
fn appendQuotedArg(allocator: std.mem.Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    var needs_quote = arg.len == 0;
    for (arg) |c| {
        if (!isShellSafeArgChar(c)) needs_quote = true;
    }
    if (!needs_quote) {
        try out.appendSlice(allocator, arg);
        return;
    }
    try out.append(allocator, '\'');
    for (arg) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
}

/// Builds a corrected invocation for a `requires_dashdash` command that was
/// called without its mandatory '--', e.g. `moon exec -- sh -c 'echo ok'`.
/// `leaf_args` is exactly what this leaf command's own parse loop received
/// (i.e. after `moon` and any parent group names were already consumed by
/// dispatch); `offending_index` is the index within it of the first token
/// that was collected as a positional before any '--' was seen. Inserting
/// '--' there is always a valid fix regardless of how many such positionals
/// a given command allows before the wrapped command itself (e.g. the orbit
/// selector in `moon orbit exec <orbit> -- <command>`), because the router
/// only ever tries to flag-parse tokens before '--' — a plain positional
/// like an orbit name parses identically whether '--' precedes or follows
/// it.
fn buildMissingDashDashSuggestion(
    allocator: std.mem.Allocator,
    ctx: *Context,
    leaf_args: []const []const u8,
    offending_index: usize,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "moon");

    // ctx.all_args is [program, ...subcommand path..., ...leaf_args]; the
    // subcommand path (e.g. "exec" or "orbit exec") is whatever sits
    // between the program name and leaf_args.
    if (ctx.all_args.len >= leaf_args.len + 1) {
        for (ctx.all_args[1 .. ctx.all_args.len - leaf_args.len]) |part| {
            try out.append(allocator, ' ');
            try out.appendSlice(allocator, part);
        }
    }

    for (leaf_args[0..offending_index]) |arg| {
        try out.append(allocator, ' ');
        try appendQuotedArg(allocator, &out, arg);
    }

    try out.appendSlice(allocator, " --");

    for (leaf_args[offending_index..]) |arg| {
        try out.append(allocator, ' ');
        try appendQuotedArg(allocator, &out, arg);
    }

    return out.toOwnedSlice(allocator);
}

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

    if (root.fallback_dispatch_fn) |fallback| {
        return fallback(args, ctx);
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

        if (root.fallback_complete_fn) |fallback| {
            const fallback_items = try fallback(args, ctx);
            try list.appendSlice(ctx.allocator, fallback_items);
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
                        for (args[0 .. args.len - 1]) |prev_arg| {
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

    if (root.fallback_complete_fn) |fallback| {
        return fallback(args, ctx);
    }

    return &.{};
}

const testing = std.testing;

/// Minimal stand-in for `exec`'s shape: a `requires_dashdash` leaf with a
/// couple of flags and a `positionals` field, but a no-op `run` so tests can
/// exercise the router's own parsing/diagnostics without touching a real
/// project or process.
const TestExecLikeCommand = struct {
    pub const name = "exec";
    pub const requires_dashdash = true;

    positionals: []const []const u8 = &.{},
    dev: bool = false,
    prod: bool = false,
    interpreter: ?[]const u8 = null,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print("usage: test-exec\n", .{});
    }

    pub fn run(self: @This(), ctx: *Context) !void {
        _ = self;
        _ = ctx;
    }
};

fn testContext(allocator: std.mem.Allocator, stdout: *std.Io.Writer, env_map: *std.process.Environ.Map, all_args: []const []const u8) Context {
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .stdout = stdout,
        .stderr = stdout,
        .env = env_map,
        .all_args = all_args,
    };
}

test "requires_dashdash: a positional followed by a flag-like token reports missing '--' with a corrected suggestion, not unknown flag" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var stdout_bytes: [1024]u8 = undefined;
    var stdout_writer = std.Io.Writer.fixed(&stdout_bytes);
    var env_map = std.process.Environ.Map.init(allocator);

    const leaf_args = [_][]const u8{ "sh", "-c", "echo ok" };
    const all_args = [_][]const u8{ "moon", "exec", "sh", "-c", "echo ok" };
    var ctx = testContext(allocator, &stdout_writer, &env_map, all_args[0..]);

    const node = CommandNode.from(TestExecLikeCommand);
    try testing.expectError(error.AlreadyReported, node.run_fn.?(leaf_args[0..], &ctx));

    const detail = ctx.error_detail.?;
    try testing.expect(std.meta.activeTag(detail) == .missing_dashdash);
    try testing.expectEqualStrings("exec", detail.missing_dashdash.command);
    try testing.expectEqualStrings("moon exec -- sh -c 'echo ok'", detail.missing_dashdash.suggestion);
    try testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "Try: moon exec -- sh -c 'echo ok'") != null);
}

test "requires_dashdash: a flagless command with no '--' at all still reports missing '--' with a suggestion" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var stdout_bytes: [1024]u8 = undefined;
    var stdout_writer = std.Io.Writer.fixed(&stdout_bytes);
    var env_map = std.process.Environ.Map.init(allocator);

    const leaf_args = [_][]const u8{ "luajit", "x.lua" };
    const all_args = [_][]const u8{ "moon", "exec", "luajit", "x.lua" };
    var ctx = testContext(allocator, &stdout_writer, &env_map, all_args[0..]);

    const node = CommandNode.from(TestExecLikeCommand);
    try testing.expectError(error.AlreadyReported, node.run_fn.?(leaf_args[0..], &ctx));

    const detail = ctx.error_detail.?;
    try testing.expect(std.meta.activeTag(detail) == .missing_dashdash);
    try testing.expectEqualStrings("moon exec -- luajit x.lua", detail.missing_dashdash.suggestion);
}

test "requires_dashdash: moonstone's own flags before '--' still parse normally" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var stdout_bytes: [1024]u8 = undefined;
    var stdout_writer = std.Io.Writer.fixed(&stdout_bytes);
    var env_map = std.process.Environ.Map.init(allocator);

    const leaf_args = [_][]const u8{ "--dev", "--", "sh", "-c", "x" };
    const all_args = [_][]const u8{ "moon", "exec", "--dev", "--", "sh", "-c", "x" };
    var ctx = testContext(allocator, &stdout_writer, &env_map, all_args[0..]);

    const node = CommandNode.from(TestExecLikeCommand);
    try node.run_fn.?(leaf_args[0..], &ctx);
    try testing.expect(ctx.error_detail == null);
}

test "requires_dashdash: an unknown long flag before any positional still reports unknown flag" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var stdout_bytes: [1024]u8 = undefined;
    var stdout_writer = std.Io.Writer.fixed(&stdout_bytes);
    var env_map = std.process.Environ.Map.init(allocator);

    const leaf_args = [_][]const u8{ "--bogus", "--", "x" };
    const all_args = [_][]const u8{ "moon", "exec", "--bogus", "--", "x" };
    var ctx = testContext(allocator, &stdout_writer, &env_map, all_args[0..]);

    const node = CommandNode.from(TestExecLikeCommand);
    try testing.expectError(error.AlreadyReported, node.run_fn.?(leaf_args[0..], &ctx));

    const detail = ctx.error_detail.?;
    try testing.expect(std.meta.activeTag(detail) == .unknown_flag);
    try testing.expectEqualStrings("bogus", detail.unknown_flag.flag);
    try testing.expect(detail.unknown_flag.is_long);
    try testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "Error: unknown flag --bogus for command 'exec'") != null);
}

test "an unknown short flag is echoed back with a single dash, not '--'" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var stdout_bytes: [1024]u8 = undefined;
    var stdout_writer = std.Io.Writer.fixed(&stdout_bytes);
    var env_map = std.process.Environ.Map.init(allocator);

    const leaf_args = [_][]const u8{"-x"};
    const all_args = [_][]const u8{ "moon", "exec", "-x" };
    var ctx = testContext(allocator, &stdout_writer, &env_map, all_args[0..]);

    const node = CommandNode.from(TestExecLikeCommand);
    try testing.expectError(error.AlreadyReported, node.run_fn.?(leaf_args[0..], &ctx));

    const detail = ctx.error_detail.?;
    try testing.expect(std.meta.activeTag(detail) == .unknown_flag);
    try testing.expectEqualStrings("x", detail.unknown_flag.flag);
    try testing.expect(!detail.unknown_flag.is_long);
    const printed = stdout_writer.buffered();
    try testing.expect(std.mem.indexOf(u8, printed, "Error: unknown flag -x for command 'exec'") != null);
    try testing.expect(std.mem.indexOf(u8, printed, "--x") == null);
}

test "orbit exec: a wrapped command's flag before '--' suggests inserting '--' before the orbit selector" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var stdout_bytes: [1024]u8 = undefined;
    var stdout_writer = std.Io.Writer.fixed(&stdout_bytes);
    var env_map = std.process.Environ.Map.init(allocator);

    const leaf_args = [_][]const u8{ "child", "lua", "-e", "print(1)" };
    const all_args = [_][]const u8{ "moon", "orbit", "exec", "child", "lua", "-e", "print(1)" };
    var ctx = testContext(allocator, &stdout_writer, &env_map, all_args[0..]);

    const OrbitExecCommand = @import("commands/orbit_exec.zig").OrbitExecCommand;
    const node = CommandNode.from(OrbitExecCommand);
    try testing.expectError(error.AlreadyReported, node.run_fn.?(leaf_args[0..], &ctx));

    const detail = ctx.error_detail.?;
    try testing.expect(std.meta.activeTag(detail) == .missing_dashdash);
    try testing.expectEqualStrings("moon orbit exec -- child lua -e 'print(1)'", detail.missing_dashdash.suggestion);
}

test "orbit run: a wrapped script's flag before '--' suggests inserting '--' before the orbit selector" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var stdout_bytes: [1024]u8 = undefined;
    var stdout_writer = std.Io.Writer.fixed(&stdout_bytes);
    var env_map = std.process.Environ.Map.init(allocator);

    const leaf_args = [_][]const u8{ "child", "hello", "-e", "x" };
    const all_args = [_][]const u8{ "moon", "orbit", "run", "child", "hello", "-e", "x" };
    var ctx = testContext(allocator, &stdout_writer, &env_map, all_args[0..]);

    const OrbitRunCommand = @import("commands/orbit_run.zig").OrbitRunCommand;
    const node = CommandNode.from(OrbitRunCommand);
    try testing.expectError(error.AlreadyReported, node.run_fn.?(leaf_args[0..], &ctx));

    const detail = ctx.error_detail.?;
    try testing.expect(std.meta.activeTag(detail) == .missing_dashdash);
    try testing.expectEqualStrings("moon orbit run -- child hello -e x", detail.missing_dashdash.suggestion);
}
