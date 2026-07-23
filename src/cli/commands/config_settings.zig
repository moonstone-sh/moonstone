const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");
const ndjson = @import("ndjson.zig");

const ValueKind = enum { string, boolean, integer };

const Setting = struct {
    key: []const u8,
    section: []const u8,
    field: []const u8,
    kind: ValueKind,
    default_value: []const u8,
};

const settings = [_]Setting{
    .{ .key = "paths.home_directory", .section = "paths", .field = "home_directory", .kind = .string, .default_value = "<environment/XDG default>" },
    .{ .key = "paths.store", .section = "paths", .field = "store", .kind = .string, .default_value = "<derived from home_directory>" },
    .{ .key = "paths.cache", .section = "paths", .field = "cache", .kind = .string, .default_value = "<derived from home_directory>" },
    .{ .key = "paths.shims", .section = "paths", .field = "shims", .kind = .string, .default_value = "<derived from home_directory>" },
    .{ .key = "paths.downloads", .section = "paths", .field = "downloads", .kind = .string, .default_value = "<derived from cache>" },
    .{ .key = "network.proxy", .section = "network", .field = "proxy", .kind = .string, .default_value = "\"\"" },
    .{ .key = "network.timeout", .section = "network", .field = "timeout", .kind = .integer, .default_value = "30" },
    .{ .key = "network.verify_tls", .section = "network", .field = "verify_tls", .kind = .boolean, .default_value = "true" },
    .{ .key = "network.retries", .section = "network", .field = "retries", .kind = .integer, .default_value = "3" },
    .{ .key = "network.retry_delay", .section = "network", .field = "retry_delay", .kind = .integer, .default_value = "1" },
    .{ .key = "cli.color", .section = "cli", .field = "color", .kind = .boolean, .default_value = "true" },
    .{ .key = "cli.verbose", .section = "cli", .field = "verbose", .kind = .boolean, .default_value = "false" },
    .{ .key = "cli.confirm_on_remove", .section = "cli", .field = "confirm_on_remove", .kind = .boolean, .default_value = "true" },
    .{ .key = "cache.manifest_cache", .section = "cache", .field = "manifest_cache", .kind = .boolean, .default_value = "true" },
    .{ .key = "cache.manifest_ttl", .section = "cache", .field = "manifest_ttl", .kind = .string, .default_value = "\"24h\"" },
    .{ .key = "telemetry.enabled", .section = "telemetry", .field = "enabled", .kind = .boolean, .default_value = "false" },
};

fn settingFor(key: []const u8) !Setting {
    for (settings) |setting| if (std.mem.eql(u8, setting.key, key)) return setting;
    return error.InvalidConfigSetting;
}

fn sectionRange(content: []const u8, section: []const u8) ?struct { start: usize, end: usize } {
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']' and std.mem.eql(u8, trimmed[1 .. trimmed.len - 1], section)) {
            const start = offset + line.len + @as(usize, @intFromBool(offset + line.len < content.len));
            var end = content.len;
            var next_offset = start;
            const remaining = content[start..];
            var following = std.mem.splitScalar(u8, remaining, '\n');
            while (following.next()) |next_line| {
                const next_trimmed = std.mem.trim(u8, next_line, " \t\r");
                if (next_trimmed.len >= 2 and next_trimmed[0] == '[' and next_trimmed[next_trimmed.len - 1] == ']') {
                    end = next_offset;
                    break;
                }
                next_offset += next_line.len + @as(usize, @intFromBool(next_offset + next_line.len < content.len));
            }
            return .{ .start = start, .end = end };
        }
        offset += line.len + @as(usize, @intFromBool(offset + line.len < content.len));
    }
    return null;
}

fn assignmentRange(content: []const u8, section: []const u8, field: []const u8) ?struct { start: usize, end: usize, value: []const u8 } {
    const range = sectionRange(content, section) orelse return null;
    var offset = range.start;
    var lines = std.mem.splitScalar(u8, content[range.start..range.end], '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, field)) {
            const remainder = std.mem.trim(u8, trimmed[field.len..], " \t");
            if (remainder.len > 0 and remainder[0] == '=') {
                return .{
                    .start = offset,
                    .end = offset + line.len + @as(usize, @intFromBool(offset + line.len < content.len)),
                    .value = std.mem.trim(u8, remainder[1..], " \t\r"),
                };
            }
        }
        offset += line.len + @as(usize, @intFromBool(offset + line.len < content.len));
    }
    return null;
}

fn readConfig(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return try allocator.dupe(u8, "");
        return err;
    };
}

fn writeConfig(io: std.Io, path: []const u8, content: []const u8) !void {
    const existing_stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| blk: {
        if (err == error.FileNotFound) break :blk null;
        if (err == error.PermissionDenied or err == error.ReadOnlyFileSystem) return error.ConfigFileReadOnly;
        return err;
    };
    if (existing_stat) |stat| if (stat.permissions.readOnly()) return error.ConfigFileReadOnly;

    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch |err| {
            if (err == error.PermissionDenied or err == error.ReadOnlyFileSystem) return error.ConfigFileReadOnly;
            return err;
        };
    }
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        if (err == error.PermissionDenied or err == error.ReadOnlyFileSystem) return error.ConfigFileReadOnly;
        return err;
    };
    defer file.close(io);
    file.writeStreamingAll(io, content) catch |err| {
        if (err == error.PermissionDenied or err == error.ReadOnlyFileSystem) return error.ConfigFileReadOnly;
        return err;
    };
}

fn quotedValue(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, value, "\"\r\n") != null) return error.InvalidConfigValue;
    return try std.fmt.allocPrint(allocator, "\"{s}\"", .{value});
}

fn validatedValue(allocator: std.mem.Allocator, setting: Setting, value: []const u8) ![]const u8 {
    return switch (setting.kind) {
        .string => quotedValue(allocator, value),
        .boolean => if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) try allocator.dupe(u8, value) else error.InvalidConfigValue,
        .integer => blk: {
            _ = try std.fmt.parseInt(u32, value, 10);
            break :blk try allocator.dupe(u8, value);
        },
    };
}

fn setValue(allocator: std.mem.Allocator, content: []const u8, setting: Setting, literal: []const u8) ![]const u8 {
    const replacement = try std.fmt.allocPrint(allocator, "{s} = {s}\n", .{ setting.field, literal });
    defer allocator.free(replacement);

    if (assignmentRange(content, setting.section, setting.field)) |range| {
        return try std.mem.concat(allocator, u8, &.{ content[0..range.start], replacement, content[range.end..] });
    }
    if (sectionRange(content, setting.section)) |range| {
        const separator = if (range.end > 0 and content[range.end - 1] == '\n') "" else "\n";
        return try std.mem.concat(allocator, u8, &.{ content[0..range.end], separator, replacement, content[range.end..] });
    }
    const prefix = if (content.len == 0 or content[content.len - 1] == '\n') "" else "\n";
    const header = try std.fmt.allocPrint(allocator, "{s}[{s}]\n", .{ prefix, setting.section });
    defer allocator.free(header);
    return try std.mem.concat(allocator, u8, &.{ content, header, replacement });
}

fn unsetValue(allocator: std.mem.Allocator, content: []const u8, setting: Setting) !?[]const u8 {
    const range = assignmentRange(content, setting.section, setting.field) orelse return null;
    return try std.mem.concat(allocator, u8, &.{ content[0..range.start], content[range.end..] });
}

fn defaultValue(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, setting: Setting) ![]const u8 {
    if (std.mem.startsWith(u8, setting.key, "paths.")) {
        var paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer paths.deinit(allocator);
        const value = if (std.mem.eql(u8, setting.field, "home_directory")) setting.default_value else if (std.mem.eql(u8, setting.field, "store")) paths.store else if (std.mem.eql(u8, setting.field, "cache")) paths.cache else if (std.mem.eql(u8, setting.field, "shims")) paths.shims else paths.downloads;
        return try allocator.dupe(u8, value);
    }
    return try allocator.dupe(u8, setting.default_value);
}

pub const ConfigGetCommand = struct {
    pub const name = "get";
    pub const description = "Read an effective Moonstone configuration setting";
    positionals: []const []const u8 = &.{},
    default: bool = false,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon config get <setting> [--default]
            \\
            \\Read one typed setting. --default prints the built-in value rather
            \\than a value set in the active configuration file.
            \\
        , .{});
    }

    pub fn complete(args: []const []const u8, ctx: *router.Context) ![]const []const u8 {
        if (args.len > 1) return &.{};
        const prefix = if (args.len == 0) "" else args[0];
        var result = std.ArrayList([]const u8).empty;
        for (settings) |setting| if (std.mem.startsWith(u8, setting.key, prefix)) try result.append(ctx.allocator, setting.key);
        return result.toOwnedSlice(ctx.allocator);
    }

    pub fn run(self: ConfigGetCommand, ctx: *router.Context) !void {
        if (self.positionals.len != 1) return error.MissingArgument;
        const setting = try settingFor(self.positionals[0]);
        const config_file = try moonstone.platform.fs.resolve_config_file(ctx.allocator, ctx.env);
        defer ctx.allocator.free(config_file);
        const content = try readConfig(ctx.allocator, ctx.io, config_file);
        defer ctx.allocator.free(content);

        if (!self.default) if (assignmentRange(content, setting.section, setting.field)) |assignment| {
            if (self.json) {
                var emitter = ndjson.Emitter.init(ctx.allocator, ctx.stdout, "config-get");
                try emitter.terminate(ctx.io, setting.key, "ok", .{ .value = assignment.value, .source = "config" });
            } else try ctx.stdout.print("{s} = {s} (config)\n", .{ setting.key, assignment.value });
            return;
        };

        const value = try defaultValue(ctx.allocator, ctx.io, ctx.env, setting);
        defer ctx.allocator.free(value);
        if (self.json) {
            var emitter = ndjson.Emitter.init(ctx.allocator, ctx.stdout, "config-get");
            try emitter.terminate(ctx.io, setting.key, "ok", .{ .value = value, .source = "default" });
        } else try ctx.stdout.print("{s} = {s} (default)\n", .{ setting.key, value });
    }
};

pub const ConfigSetCommand = struct {
    pub const name = "set";
    pub const description = "Set a typed Moonstone configuration setting";
    positionals: []const []const u8 = &.{},
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon config set <setting> <value>
            \\
            \\Set one supported setting in the active configuration file.
            \\Use `moon config unset <setting>` to restore normal precedence.
            \\
        , .{});
    }

    pub fn complete(args: []const []const u8, ctx: *router.Context) ![]const []const u8 {
        return ConfigGetCommand.complete(args, ctx);
    }

    pub fn run(self: ConfigSetCommand, ctx: *router.Context) !void {
        if (self.positionals.len != 2) return error.MissingArgument;
        const setting = try settingFor(self.positionals[0]);
        const literal = try validatedValue(ctx.allocator, setting, self.positionals[1]);
        defer ctx.allocator.free(literal);
        const config_file = try moonstone.platform.fs.resolve_config_file(ctx.allocator, ctx.env);
        defer ctx.allocator.free(config_file);
        const content = try readConfig(ctx.allocator, ctx.io, config_file);
        defer ctx.allocator.free(content);
        const updated = try setValue(ctx.allocator, content, setting, literal);
        defer ctx.allocator.free(updated);
        try writeConfig(ctx.io, config_file, updated);
        if (self.json) {
            var emitter = ndjson.Emitter.init(ctx.allocator, ctx.stdout, "config-set");
            try emitter.terminate(ctx.io, setting.key, "ok", .{ .config_file = config_file, .value = literal });
        } else try ctx.stdout.print("Set {s} in {s}.\n", .{ setting.key, config_file });
    }
};

pub const ConfigUnsetCommand = struct {
    pub const name = "unset";
    pub const description = "Remove a Moonstone configuration override";
    positionals: []const []const u8 = &.{},
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon config unset <setting>
            \\
            \\Remove one override from the active configuration file.
            \\
        , .{});
    }

    pub fn complete(args: []const []const u8, ctx: *router.Context) ![]const []const u8 {
        return ConfigGetCommand.complete(args, ctx);
    }

    pub fn run(self: ConfigUnsetCommand, ctx: *router.Context) !void {
        if (self.positionals.len != 1) return error.MissingArgument;
        const setting = try settingFor(self.positionals[0]);
        const config_file = try moonstone.platform.fs.resolve_config_file(ctx.allocator, ctx.env);
        defer ctx.allocator.free(config_file);
        const content = try readConfig(ctx.allocator, ctx.io, config_file);
        defer ctx.allocator.free(content);
        const updated = try unsetValue(ctx.allocator, content, setting) orelse {
            if (self.json) {
                var emitter = ndjson.Emitter.init(ctx.allocator, ctx.stdout, "config-unset");
                try emitter.terminate(ctx.io, setting.key, "ok", .{ .config_file = config_file, .changed = false });
            } else try ctx.stdout.print("{s} is already using its default.\n", .{setting.key});
            return;
        };
        defer ctx.allocator.free(updated);
        try writeConfig(ctx.io, config_file, updated);
        if (self.json) {
            var emitter = ndjson.Emitter.init(ctx.allocator, ctx.stdout, "config-unset");
            try emitter.terminate(ctx.io, setting.key, "ok", .{ .config_file = config_file, .changed = true });
        } else try ctx.stdout.print("Unset {s} in {s}.\n", .{ setting.key, config_file });
    }
};
