const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");
const file_commands = @import("registry_file.zig");

const Target = struct {
    path: []const u8,
};

fn usage(stdout: *std.Io.Writer) !void {
    try stdout.print(
        \\Usage: moon registry <name>: <operation> [flags]
        \\       moon registry --file <path> <operation> [flags]
        \\       moon registry init --file <path> [--name <name>]
        \\
        \\Target operations:
        \\  publish --descriptor <package.toml> --artifact <archive>
        \\  index rebuild [--no-compact]
        \\  fetch --descriptor <name>@<version> [--output <path>]
        \\  package delete <name>@<version>
        \\  settings show
        \\  doctor
        \\
        \\A trailing colon marks a configured registry target. Registry names
        \\are resolved from the user config and current project, with project
        \\entries taking precedence.
        \\
    , .{});
}

fn targetForName(ctx: *router.Context, name: []const u8) !Target {
    const registries = try moonstone.registry.resolver.resolve(ctx.allocator, ctx.io, ctx.env);
    defer moonstone.registry.core.deinitResolved(registries, ctx.allocator);

    for (registries) |registry| {
        if (!std.mem.eql(u8, registry.name, name)) continue;
        if (!std.mem.startsWith(u8, registry.url, "file://")) return error.UnsupportedRegistryTransport;
        return .{ .path = try ctx.allocator.dupe(u8, registry.url["file://".len..]) };
    }
    return error.RegistryNotFound;
}

fn targetFromArgs(ctx: *router.Context, args: []const []const u8) !struct { target: Target, operation_index: usize } {
    if (args.len >= 2 and std.mem.eql(u8, args[0], "--file")) {
        return .{ .target = .{ .path = try ctx.allocator.dupe(u8, args[1]) }, .operation_index = 2 };
    }
    if (args.len >= 1 and std.mem.endsWith(u8, args[0], ":")) {
        const name = args[0][0 .. args[0].len - 1];
        if (name.len == 0) return error.MissingArgument;
        return .{ .target = try targetForName(ctx, name), .operation_index = 1 };
    }
    return error.MissingArgument;
}

fn option(args: []const []const u8, name: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index + 1 < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], name)) return args[index + 1];
    }
    return null;
}

fn hasFlag(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, name)) return true;
    return false;
}

fn splitPackageSpec(spec: []const u8) !struct { name: []const u8, version: []const u8 } {
    const at = std.mem.lastIndexOfScalar(u8, spec, '@') orelse return error.InvalidPackageSpec;
    if (at == 0 or at + 1 == spec.len) return error.InvalidPackageSpec;
    return .{ .name = spec[0..at], .version = spec[at + 1 ..] };
}

fn configureCredentialProvider(ctx: *router.Context, registry_name: []const u8, provider_path: []const u8) !void {
    const content = try std.Io.Dir.cwd().readFileAlloc(ctx.io, "moonstone.toml", ctx.allocator, std.Io.Limit.limited(1024 * 1024));
    defer ctx.allocator.free(content);
    var project = try moonstone.domain.manifest.MoonstoneToml.parse(ctx.allocator, content);
    defer project.deinit(ctx.allocator);

    const config = project.registries.getPtr(registry_name) orelse return error.RegistryNotFound;
    if (config.credential_provider) |old| ctx.allocator.free(old);
    config.credential_provider = try ctx.allocator.dupe(u8, provider_path);

    const manifest_file = try std.Io.Dir.cwd().createFile(ctx.io, "moonstone.toml", .{});
    defer manifest_file.close(ctx.io);
    var writer = std.Io.Writer.Allocating.init(ctx.allocator);
    defer writer.deinit();
    try project.serialize(ctx.allocator, &writer.writer);
    try writer.writer.flush();
    try manifest_file.writeStreamingAll(ctx.io, writer.writer.buffer[0..writer.writer.end]);

    const current_ignore = std.Io.Dir.cwd().readFileAlloc(ctx.io, ".gitignore", ctx.allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try ctx.allocator.dupe(u8, ""),
        else => return err,
    };
    defer ctx.allocator.free(current_ignore);
    if (std.mem.indexOf(u8, current_ignore, "*.auth.lua") == null) {
        const ignore_file = try std.Io.Dir.cwd().createFile(ctx.io, ".gitignore", .{});
        defer ignore_file.close(ctx.io);
        try ignore_file.writeStreamingAll(ctx.io, current_ignore);
        if (current_ignore.len > 0 and current_ignore[current_ignore.len - 1] != '\n') try ignore_file.writeStreamingAll(ctx.io, "\n");
        try ignore_file.writeStreamingAll(ctx.io, "*.auth.lua\n");
    }
    try ctx.stdout.print("Configured credential provider for registry '{s}'.\n", .{registry_name});
}

fn doctor(ctx: *router.Context, registry_path: []const u8) !void {
    const required = [_][]const u8{ "registry.toml", "index.toml", "index.sqlite.zst", "blobs/b3" };
    var missing = std.ArrayList([]const u8).empty;
    defer missing.deinit(ctx.allocator);

    for (required) |relative_path| {
        const absolute_path = try std.fs.path.join(ctx.allocator, &.{ registry_path, relative_path });
        defer ctx.allocator.free(absolute_path);
        std.Io.Dir.cwd().access(ctx.io, absolute_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                try missing.append(ctx.allocator, relative_path);
                continue;
            }
            return err;
        };
    }

    if (missing.items.len > 0) {
        try ctx.stdout.print("Registry {s} is incomplete; missing:\n", .{registry_path});
        for (missing.items) |relative_path| try ctx.stdout.print("  - {s}\n", .{relative_path});
        return error.RegistryHealthCheckFailed;
    }

    try ctx.stdout.print("Registry {s} is healthy: metadata, TOML index, compact index, and blob root are present.\n", .{registry_path});
}

pub fn dispatch(args: []const []const u8, ctx: *router.Context) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) return usage(ctx.stdout);

    if (std.mem.eql(u8, args[0], "init")) {
        const path = option(args[1..], "--file") orelse return error.MissingArgument;
        const name = option(args[1..], "--name") orelse "local";
        return (file_commands.RegistryCreateCommand{ .positionals = &.{path}, .name_arg = name }).run(ctx);
    }

    if (args.len >= 2 and std.mem.endsWith(u8, args[0], ":") and std.mem.eql(u8, args[1], "auth")) {
        const registry_name = args[0][0 .. args[0].len - 1];
        const provider_path = option(args[2..], "--file") orelse return error.MissingArgument;
        return configureCredentialProvider(ctx, registry_name, provider_path);
    }

    const resolved = try targetFromArgs(ctx, args);
    defer ctx.allocator.free(resolved.target.path);
    if (resolved.operation_index >= args.len) return error.MissingArgument;

    const operation = args[resolved.operation_index];
    const rest = args[resolved.operation_index + 1 ..];
    if (std.mem.eql(u8, operation, "publish")) {
        const descriptor = option(rest, "--descriptor") orelse return error.MissingArgument;
        const artifact = option(rest, "--artifact") orelse option(rest, "--blob") orelse return error.MissingArgument;
        return (file_commands.RegistryPushCommand{
            .registry = resolved.target.path,
            .descriptor = descriptor,
            .blob = artifact,
            .update = hasFlag(rest, "--update"),
            .replace = hasFlag(rest, "--replace"),
            .yes = hasFlag(rest, "--yes"),
            .json = hasFlag(rest, "--json"),
        }).run(ctx);
    }
    if (std.mem.eql(u8, operation, "index") and rest.len >= 1 and std.mem.eql(u8, rest[0], "rebuild")) {
        return (file_commands.RegistrySyncCommand{ .positionals = &.{resolved.target.path}, .json = hasFlag(rest, "--json") }).run(ctx);
    }
    if (std.mem.eql(u8, operation, "package") and rest.len >= 2 and std.mem.eql(u8, rest[0], "delete")) {
        const package = try splitPackageSpec(rest[1]);
        return (file_commands.RegistryPurgeCommand{
            .registry = resolved.target.path,
            .p_name = package.name,
            .version = package.version,
            .json = hasFlag(rest, "--json"),
        }).run(ctx);
    }
    if (std.mem.eql(u8, operation, "fetch")) {
        const descriptor = option(rest, "--descriptor") orelse return error.MissingArgument;
        const package = try splitPackageSpec(descriptor);
        const source = try std.fs.path.join(ctx.allocator, &.{ resolved.target.path, "packages", package.name, package.version, "package.toml" });
        defer ctx.allocator.free(source);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(ctx.io, source, ctx.allocator, std.Io.Limit.limited(16 * 1024 * 1024));
        defer ctx.allocator.free(bytes);
        if (option(rest, "--output")) |output| {
            const file = try std.Io.Dir.cwd().createFile(ctx.io, output, .{});
            defer file.close(ctx.io);
            try file.writeStreamingAll(ctx.io, bytes);
        } else {
            try ctx.stdout.writeAll(bytes);
        }
        return;
    }
    if (std.mem.eql(u8, operation, "settings") and rest.len >= 1 and std.mem.eql(u8, rest[0], "show")) {
        const source = try std.fs.path.join(ctx.allocator, &.{ resolved.target.path, "registry.toml" });
        defer ctx.allocator.free(source);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(ctx.io, source, ctx.allocator, std.Io.Limit.limited(1024 * 1024));
        defer ctx.allocator.free(bytes);
        try ctx.stdout.writeAll(bytes);
        return;
    }
    if (std.mem.eql(u8, operation, "doctor") and rest.len == 0) {
        return doctor(ctx, resolved.target.path);
    }

    return error.UnsupportedRegistryOperation;
}

pub fn complete(args: []const []const u8, ctx: *router.Context) ![]const []const u8 {
    var suggestions = std.ArrayList([]const u8).empty;
    const prefix = if (args.len == 0) "" else args[args.len - 1];

    if (args.len <= 1) {
        const globals = [_][]const u8{"init"};
        for (globals) |verb| if (std.mem.startsWith(u8, verb, prefix)) try suggestions.append(ctx.allocator, verb);

        const registries = moonstone.registry.resolver.resolve(ctx.allocator, ctx.io, ctx.env) catch return suggestions.toOwnedSlice(ctx.allocator);
        defer moonstone.registry.core.deinitResolved(registries, ctx.allocator);
        for (registries) |registry| {
            const candidate = try std.fmt.allocPrint(ctx.allocator, "{s}:", .{registry.name});
            if (std.mem.startsWith(u8, candidate, prefix)) try suggestions.append(ctx.allocator, candidate) else ctx.allocator.free(candidate);
        }
        return suggestions.toOwnedSlice(ctx.allocator);
    }

    if (std.mem.endsWith(u8, args[0], ":") or std.mem.eql(u8, args[0], "--file")) {
        const verbs = [_][]const u8{ "publish", "index", "fetch", "package", "settings", "doctor", "auth" };
        for (verbs) |verb| if (std.mem.startsWith(u8, verb, prefix)) try suggestions.append(ctx.allocator, verb);
    }
    return suggestions.toOwnedSlice(ctx.allocator);
}
