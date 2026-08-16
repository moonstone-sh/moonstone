const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

fn readLock(ctx: *router.Context) !struct { raw: []u8, value: moonstone.domain.lockfile.LockFile } {
    const raw = try std.Io.Dir.cwd().readFileAlloc(ctx.io, "moonstone.lock", ctx.allocator, std.Io.Limit.limited(10 * 1024 * 1024));
    errdefer ctx.allocator.free(raw);
    return .{ .raw = raw, .value = try moonstone.domain.lockfile.LockFile.parse(ctx.allocator, raw) };
}

pub const LockExportCommand = struct {
    pub const name = "export";
    pub const description = "Export the lockfile through the versioned JSON protocol";
    json: bool = false,
    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print("Usage: moon lock export --json\n", .{});
    }
    pub fn run(self: LockExportCommand, ctx: *router.Context) !void {
        if (!self.json) return error.LockJsonRequired;
        var loaded = try readLock(ctx);
        defer ctx.allocator.free(loaded.raw);
        defer loaded.value.deinit();
        try moonstone.domain.lock_protocol.writeExport(ctx.allocator, &loaded.value, loaded.raw, ctx.stdout);
    }
};

pub const LockVerifyCommand = struct {
    pub const name = "verify";
    pub const description = "Verify that moonstone.lock is readable and structurally valid";
    json: bool = false,
    target_arg: ?[]const u8 = null,
    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print("Usage: moon lock verify [--target <triple>] --json\n", .{});
    }
    pub fn run(self: LockVerifyCommand, ctx: *router.Context) !void {
        if (!self.json) return error.LockJsonRequired;
        var loaded = try readLock(ctx);
        defer ctx.allocator.free(loaded.raw);
        defer loaded.value.deinit();
        const selected_profile = if (self.target_arg) |target| blk: {
            try moonstone.platform.target.validate(target);
            for (loaded.value.profiles.items) |*profile| {
                if (std.mem.eql(u8, profile.target, target)) break :blk profile;
            }
            return error.TargetProfileNotFound;
        } else null;
        const revision = try moonstone.domain.lock_protocol.storageRevision(ctx.allocator, loaded.raw);
        defer ctx.allocator.free(revision);
        try ctx.stdout.writeAll("{\"contract\":\"moonstone:lock-verify:v1\",\"valid\":true,\"storage_revision\":");
        try std.json.Stringify.value(revision, .{}, ctx.stdout);
        try ctx.stdout.print(",\"realization_count\":{d},\"profile_count\":{d}", .{ loaded.value.packages.items.len, loaded.value.profiles.items.len });
        if (selected_profile) |profile| {
            try ctx.stdout.writeAll(",\"profile\":");
            try std.json.Stringify.value(profile.id, .{}, ctx.stdout);
        }
        try ctx.stdout.writeAll("}\n");
    }
};

pub const LockProfileListCommand = struct {
    pub const name = "list";
    pub const description = "List locked resolution profiles";
    json: bool = false,
    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print("Usage: moon lock profile list --json\n", .{});
    }
    pub fn run(self: LockProfileListCommand, ctx: *router.Context) !void {
        if (!self.json) return error.LockJsonRequired;
        var loaded = try readLock(ctx);
        defer ctx.allocator.free(loaded.raw);
        defer loaded.value.deinit();
        try ctx.stdout.writeAll("{\"contract\":\"moonstone:lock-profile-list:v1\",\"profiles\":[");
        for (loaded.value.profiles.items, 0..) |profile, index| {
            if (index > 0) try ctx.stdout.writeAll(",");
            try ctx.stdout.writeAll("{\"id\":");
            try std.json.Stringify.value(profile.id, .{}, ctx.stdout);
            try ctx.stdout.writeAll(",\"target\":");
            try std.json.Stringify.value(profile.target, .{}, ctx.stdout);
            try ctx.stdout.writeAll(",\"runtime\":");
            try std.json.Stringify.value(profile.runtime, .{}, ctx.stdout);
            try ctx.stdout.print(",\"package_count\":{d}}}", .{profile.packages.len});
        }
        try ctx.stdout.writeAll("]}\n");
    }
};

pub const LockPackageListCommand = struct {
    pub const name = "list";
    pub const description = "List locked packages";
    json: bool = false,
    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print("Usage: moon lock package list --json\n", .{});
    }
    pub fn run(self: LockPackageListCommand, ctx: *router.Context) !void {
        if (!self.json) return error.LockJsonRequired;
        var loaded = try readLock(ctx);
        defer ctx.allocator.free(loaded.raw);
        defer loaded.value.deinit();
        try ctx.stdout.writeAll("{\"contract\":\"moonstone:lock-package-list:v1\",\"packages\":[");
        for (loaded.value.packages.items, 0..) |package, index| {
            if (index > 0) try ctx.stdout.writeAll(",");
            try ctx.stdout.writeAll("{\"name\":");
            try std.json.Stringify.value(package.name, .{}, ctx.stdout);
            try ctx.stdout.writeAll(",\"version\":");
            try std.json.Stringify.value(package.version, .{}, ctx.stdout);
            try ctx.stdout.writeAll(",\"artifact_hash\":");
            try std.json.Stringify.value(package.artifact_hash, .{}, ctx.stdout);
            try ctx.stdout.writeAll("}");
        }
        try ctx.stdout.writeAll("]}\n");
    }
};

pub const LockPackageGetCommand = struct {
    pub const name = "get";
    pub const description = "Inspect one locked package and its provenance";
    positionals: []const []const u8 = &.{},
    json: bool = false,
    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print("Usage: moon lock package get <name> --json\n", .{});
    }
    pub fn run(self: LockPackageGetCommand, ctx: *router.Context) !void {
        if (!self.json) return error.LockJsonRequired;
        if (self.positionals.len == 0) return error.MissingArgument;
        var loaded = try readLock(ctx);
        defer ctx.allocator.free(loaded.raw);
        defer loaded.value.deinit();
        const package = loaded.value.find(self.positionals[0]) orelse return error.PackageNotFound;
        try ctx.stdout.writeAll("{\"contract\":\"moonstone:lock-package:v1\",\"package\":{\"name\":");
        try std.json.Stringify.value(package.name, .{}, ctx.stdout);
        try ctx.stdout.writeAll(",\"version\":");
        try std.json.Stringify.value(package.version, .{}, ctx.stdout);
        try ctx.stdout.writeAll(",\"resolver\":");
        try std.json.Stringify.value(package.resolver, .{}, ctx.stdout);
        try ctx.stdout.writeAll(",\"registry\":");
        try std.json.Stringify.value(package.registry, .{}, ctx.stdout);
        try ctx.stdout.writeAll(",\"source_hash\":");
        try std.json.Stringify.value(package.source_hash, .{}, ctx.stdout);
        try ctx.stdout.writeAll(",\"recipe_hash\":");
        try std.json.Stringify.value(package.recipe_hash, .{}, ctx.stdout);
        try ctx.stdout.writeAll(",\"artifact_hash\":");
        try std.json.Stringify.value(package.artifact_hash, .{}, ctx.stdout);
        try ctx.stdout.writeAll(",\"target\":");
        try std.json.Stringify.value(package.target, .{}, ctx.stdout);
        try ctx.stdout.writeAll(",\"replay_mode\":");
        try std.json.Stringify.value(@tagName(package.replay_mode), .{}, ctx.stdout);
        try ctx.stdout.print(",\"reproducible\":{s}", .{if (package.reproducible) "true" else "false"});
        try ctx.stdout.writeAll("}}\n");
    }
};

pub const LockProfileGetCommand = struct {
    pub const name = "get";
    pub const description = "Inspect one locked profile and its graph summary";
    positionals: []const []const u8 = &.{},
    json: bool = false,
    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print("Usage: moon lock profile get <id> --json\n", .{});
    }
    pub fn run(self: LockProfileGetCommand, ctx: *router.Context) !void {
        if (!self.json) return error.LockJsonRequired;
        if (self.positionals.len == 0) return error.MissingArgument;
        var loaded = try readLock(ctx);
        defer ctx.allocator.free(loaded.raw);
        defer loaded.value.deinit();
        var profile: ?*const moonstone.domain.resolution_profile.ResolutionProfile = null;
        for (loaded.value.profiles.items) |*candidate| {
            if (std.mem.eql(u8, candidate.id, self.positionals[0])) {
                profile = candidate;
                break;
            }
        }
        const actual = profile orelse return error.ProfileNotFound;
        try ctx.stdout.writeAll("{\"contract\":\"moonstone:lock-profile:v1\",\"profile\":{\"id\":");
        try std.json.Stringify.value(actual.id, .{}, ctx.stdout);
        try ctx.stdout.writeAll(",\"target\":");
        try std.json.Stringify.value(actual.target, .{}, ctx.stdout);
        try ctx.stdout.writeAll(",\"runtime\":");
        try std.json.Stringify.value(actual.runtime, .{}, ctx.stdout);
        try ctx.stdout.writeAll(",\"packages\":[");
        for (actual.packages, 0..) |package, index| {
            if (index > 0) try ctx.stdout.writeAll(",");
            try ctx.stdout.writeAll("{\"name\":");
            try std.json.Stringify.value(package.package_name, .{}, ctx.stdout);
            try ctx.stdout.writeAll(",\"version\":");
            try std.json.Stringify.value(package.package_version, .{}, ctx.stdout);
            try ctx.stdout.writeAll("}");
        }
        try ctx.stdout.writeAll("],\"edges\":[");
        for (actual.edges, 0..) |edge, index| {
            if (index > 0) try ctx.stdout.writeAll(",");
            try ctx.stdout.writeAll("{\"from\":");
            try std.json.Stringify.value(edge.from_package, .{}, ctx.stdout);
            try ctx.stdout.writeAll(",\"to\":");
            try std.json.Stringify.value(edge.to_package, .{}, ctx.stdout);
            try ctx.stdout.writeAll("}");
        }
        try ctx.stdout.writeAll("]}}\n");
    }
};

pub const LockRealizationListCommand = struct {
    pub const name = "list";
    pub const description = "List locked profile realizations";
    json: bool = false,
    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print("Usage: moon lock realization list --json\n", .{});
    }
    pub fn run(self: LockRealizationListCommand, ctx: *router.Context) !void {
        if (!self.json) return error.LockJsonRequired;
        var loaded = try readLock(ctx);
        defer ctx.allocator.free(loaded.raw);
        defer loaded.value.deinit();
        try ctx.stdout.writeAll("{\"contract\":\"moonstone:lock-realization-list:v1\",\"realizations\":[");
        var first = true;
        for (loaded.value.profiles.items) |profile| for (profile.packages) |package| {
            if (!first) try ctx.stdout.writeAll(",");
            first = false;
            try ctx.stdout.writeAll("{\"hash\":");
            try std.json.Stringify.value(package.realization_hash, .{}, ctx.stdout);
            try ctx.stdout.writeAll(",\"profile\":");
            try std.json.Stringify.value(profile.id, .{}, ctx.stdout);
            try ctx.stdout.writeAll(",\"package\":");
            try std.json.Stringify.value(package.package_name, .{}, ctx.stdout);
            try ctx.stdout.writeAll(",\"version\":");
            try std.json.Stringify.value(package.package_version, .{}, ctx.stdout);
            try ctx.stdout.writeAll("}");
        };
        try ctx.stdout.writeAll("]}\n");
    }
};

pub const LockRealizationGetCommand = struct {
    pub const name = "get";
    pub const description = "Inspect one locked realization by hash";
    positionals: []const []const u8 = &.{},
    json: bool = false,
    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print("Usage: moon lock realization get <hash> --json\n", .{});
    }
    pub fn run(self: LockRealizationGetCommand, ctx: *router.Context) !void {
        if (!self.json) return error.LockJsonRequired;
        if (self.positionals.len == 0) return error.MissingArgument;
        var loaded = try readLock(ctx);
        defer ctx.allocator.free(loaded.raw);
        defer loaded.value.deinit();
        for (loaded.value.profiles.items) |profile| for (profile.packages) |reference| {
            if (!std.mem.eql(u8, reference.realization_hash, self.positionals[0])) continue;
            const package = loaded.value.findRealization(reference.realization_hash);
            try ctx.stdout.writeAll("{\"contract\":\"moonstone:lock-realization:v1\",\"realization\":{\"hash\":");
            try std.json.Stringify.value(reference.realization_hash, .{}, ctx.stdout);
            try ctx.stdout.writeAll(",\"profile\":");
            try std.json.Stringify.value(profile.id, .{}, ctx.stdout);
            try ctx.stdout.writeAll(",\"package\":");
            try std.json.Stringify.value(reference.package_name, .{}, ctx.stdout);
            try ctx.stdout.writeAll(",\"version\":");
            try std.json.Stringify.value(reference.package_version, .{}, ctx.stdout);
            try ctx.stdout.writeAll(",\"artifact_hash\":");
            if (package) |entry| try std.json.Stringify.value(entry.artifact_hash, .{}, ctx.stdout) else try ctx.stdout.writeAll("null");
            try ctx.stdout.writeAll("}}\n");
            return;
        };
        if (loaded.value.findRealization(self.positionals[0])) |entry| {
            try ctx.stdout.writeAll("{\"contract\":\"moonstone:lock-realization:v1\",\"realization\":{\"hash\":");
            try std.json.Stringify.value(entry.realization_hash, .{}, ctx.stdout);
            try ctx.stdout.writeAll(",\"package\":");
            try std.json.Stringify.value(entry.name, .{}, ctx.stdout);
            try ctx.stdout.writeAll(",\"version\":");
            try std.json.Stringify.value(entry.version, .{}, ctx.stdout);
            try ctx.stdout.writeAll(",\"artifact_hash\":");
            try std.json.Stringify.value(entry.artifact_hash, .{}, ctx.stdout);
            try ctx.stdout.writeAll("}}\n");
            return;
        }
        return error.RealizationNotFound;
    }
};

pub const LockGraphExportCommand = struct {
    pub const name = "export";
    pub const description = "Export locked dependency graphs for every profile";
    json: bool = false,
    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print("Usage: moon lock graph export --json\n", .{});
    }
    pub fn run(self: LockGraphExportCommand, ctx: *router.Context) !void {
        if (!self.json) return error.LockJsonRequired;
        var loaded = try readLock(ctx);
        defer ctx.allocator.free(loaded.raw);
        defer loaded.value.deinit();
        try ctx.stdout.writeAll("{\"contract\":\"moonstone:lock-graph:v1\",\"profiles\":[");
        for (loaded.value.profiles.items, 0..) |profile, index| {
            if (index > 0) try ctx.stdout.writeAll(",");
            try ctx.stdout.writeAll("{\"id\":");
            try std.json.Stringify.value(profile.id, .{}, ctx.stdout);
            try ctx.stdout.writeAll(",\"nodes\":[");
            for (profile.packages, 0..) |package, package_index| {
                if (package_index > 0) try ctx.stdout.writeAll(",");
                try ctx.stdout.writeAll("{\"name\":");
                try std.json.Stringify.value(package.package_name, .{}, ctx.stdout);
                try ctx.stdout.writeAll(",\"version\":");
                try std.json.Stringify.value(package.package_version, .{}, ctx.stdout);
                try ctx.stdout.writeAll(",\"realization_hash\":");
                try std.json.Stringify.value(package.realization_hash, .{}, ctx.stdout);
                try ctx.stdout.writeAll("}");
            }
            try ctx.stdout.writeAll("],\"edges\":[");
            for (profile.edges, 0..) |edge, edge_index| {
                if (edge_index > 0) try ctx.stdout.writeAll(",");
                try ctx.stdout.writeAll("{\"from\":");
                try std.json.Stringify.value(edge.from_package, .{}, ctx.stdout);
                try ctx.stdout.writeAll(",\"to\":");
                try std.json.Stringify.value(edge.to_package, .{}, ctx.stdout);
                try ctx.stdout.writeAll(",\"constraint\":");
                try std.json.Stringify.value(edge.constraint, .{}, ctx.stdout);
                try ctx.stdout.writeAll("}");
            }
            try ctx.stdout.writeAll("]}");
        }
        try ctx.stdout.writeAll("]}\n");
    }
};
