const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

fn load(ctx: *router.Context) !moonstone.project.manifest_editor.Loaded {
    const root = try moonstone.project.discovery.enterRoot(ctx.allocator, ctx.io, ".");
    defer root.deinit(ctx.allocator);
    return moonstone.project.manifest_editor.load(ctx.allocator, ctx.io, std.Io.Limit.limited(1024 * 1024));
}

fn writeScript(writer: *std.Io.Writer, script: moonstone.domain.script.ScriptDefinition) !void {
    try writer.writeAll("{\"name\":");
    try std.json.Stringify.value(script.name, .{}, writer);
    try writer.writeAll(",\"command\":");
    try std.json.Stringify.value(script.command, .{}, writer);
    try writer.writeAll("}");
}

pub const ListCommand = struct {
    pub const name = "list";
    pub const description = "List semantic manifest scripts";
    json: bool = false,
    pub fn printHelp(writer: *std.Io.Writer) !void {
        try writer.writeAll("Usage: moon manifest script list --json\n");
    }
    pub fn run(self: ListCommand, ctx: *router.Context) !void {
        if (!self.json) return error.ManifestJsonRequired;
        var loaded = try load(ctx);
        defer loaded.deinit(ctx.allocator);
        try ctx.stdout.writeAll("{\"contract\":\"moonstone:manifest-script-list:v1\",\"scripts\":[");
        for (loaded.manifest.scripts.items, 0..) |script, index| {
            if (index > 0) try ctx.stdout.writeByte(',');
            try writeScript(ctx.stdout, script);
        }
        try ctx.stdout.writeAll("]}\n");
    }
};

pub const GetCommand = struct {
    pub const name = "get";
    pub const description = "Read one semantic manifest script";
    positionals: []const []const u8 = &.{},
    json: bool = false,
    pub fn printHelp(writer: *std.Io.Writer) !void {
        try writer.writeAll("Usage: moon manifest script get <name> --json\n");
    }
    pub fn run(self: GetCommand, ctx: *router.Context) !void {
        if (!self.json) return error.ManifestJsonRequired;
        const script_name = if (self.positionals.len > 0) self.positionals[0] else return error.ScriptRequired;
        var loaded = try load(ctx);
        defer loaded.deinit(ctx.allocator);
        const script = loaded.manifest.findScript(script_name) orelse return error.ScriptNotFound;
        try ctx.stdout.writeAll("{\"contract\":\"moonstone:manifest-script:v1\",\"script\":");
        try writeScript(ctx.stdout, script.*);
        try ctx.stdout.writeAll("}\n");
    }
};

pub const SetCommand = struct {
    pub const name = "set";
    pub const description = "Create or replace one manifest script";
    positionals: []const []const u8 = &.{},
    command: ?[]const u8 = null,
    pub fn printHelp(writer: *std.Io.Writer) !void {
        try writer.writeAll("Usage: moon manifest script set <name> --command <opaque-shell-command>\n");
    }
    pub fn run(self: SetCommand, ctx: *router.Context) !void {
        const script_name = if (self.positionals.len > 0) self.positionals[0] else return error.ScriptRequired;
        const command = self.command orelse return error.MissingArgument;
        var loaded = try load(ctx);
        defer loaded.deinit(ctx.allocator);
        const updated = try moonstone.project.manifest_tidy.setScript(ctx.allocator, loaded.source, script_name, command);
        defer ctx.allocator.free(updated);
        var validated = try moonstone.domain.manifest.MoonstoneToml.parse(ctx.allocator, updated);
        defer validated.deinit(ctx.allocator);
        try moonstone.project.manifest_editor.commitSource(ctx.io, updated);
    }
};

pub const RemoveCommand = struct {
    pub const name = "remove";
    pub const description = "Remove one manifest script";
    positionals: []const []const u8 = &.{},
    pub fn printHelp(writer: *std.Io.Writer) !void {
        try writer.writeAll("Usage: moon manifest script remove <name>\n");
    }
    pub fn run(self: RemoveCommand, ctx: *router.Context) !void {
        const script_name = if (self.positionals.len > 0) self.positionals[0] else return error.ScriptRequired;
        var loaded = try load(ctx);
        defer loaded.deinit(ctx.allocator);
        const updated = try moonstone.project.manifest_tidy.removeScript(ctx.allocator, loaded.source, script_name);
        defer ctx.allocator.free(updated);
        var validated = try moonstone.domain.manifest.MoonstoneToml.parse(ctx.allocator, updated);
        defer validated.deinit(ctx.allocator);
        try moonstone.project.manifest_editor.commitSource(ctx.io, updated);
    }
};
