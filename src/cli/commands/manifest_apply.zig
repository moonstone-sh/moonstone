const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

const RuntimeInput = struct {
    name: []const u8,
    version: []const u8,
    abi: []const u8,
};

const DependencyInput = struct {
    name: []const u8,
    constraint: []const u8,
    registry: ?[]const u8 = null,
    role: []const u8 = "runtime",
    optional: bool = false,
};

const RegistryInput = struct {
    name: []const u8,
    resolver: []const u8,
    url: ?[]const u8 = null,
    path: ?[]const u8 = null,
    priority: i32 = 0,
};

const OperationInput = struct {
    kind: []const u8,
    name: ?[]const u8 = null,
    command: ?[]const u8 = null,
    runtime: ?RuntimeInput = null,
    dependency: ?DependencyInput = null,
    registry: ?RegistryInput = null,
};

const Request = struct {
    contract: []const u8,
    expected_revision: []const u8,
    operations: []const OperationInput,
};

const WriteResult = struct {
    source: []u8,
    storage_mode: []const u8,
};

pub const ManifestApplyCommand = struct {
    pub const name = "apply";
    pub const description = "Apply bounded semantic manifest operations from JSON";

    json: bool = false,
    force: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon manifest apply --json --force < request.json
            \\
            \\Apply a versioned semantic edit request. Both --json and --force are
            \\required. The request must carry the current storage_revision from
            \\`moon manifest export --json`; stale requests change nothing.
            \\
            \\Initial operations: set_script, remove_script, set_runtime,
            \\add_dependency, set_dependency, remove_dependency, set_registry,
            \\remove_registry.
            \\
        , .{});
    }

    pub fn run(self: ManifestApplyCommand, ctx: *router.Context) !void {
        if (!self.json) return error.ManifestJsonRequired;
        if (!self.force) return error.ManifestApplyRequiresForce;

        const root = try moonstone.project.discovery.enterRoot(ctx.allocator, ctx.io, ".");
        defer root.deinit(ctx.allocator);
        var loaded = try moonstone.project.manifest_editor.load(ctx.allocator, ctx.io, std.Io.Limit.limited(1024 * 1024));
        defer loaded.deinit(ctx.allocator);

        var input: [1024 * 1024]u8 = undefined;
        const stdin = std.Io.File.stdin();
        const length = try stdin.readStreaming(ctx.io, &.{&input});
        var parsed = try std.json.parseFromSlice(Request, ctx.allocator, input[0..length], .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const request = parsed.value;
        if (!std.mem.eql(u8, request.contract, "moonstone:manifest-edit:v1")) return error.UnsupportedManifestEditContract;

        const revision = try moonstone.domain.manifest_protocol.storageRevision(ctx.allocator, loaded.source);
        defer ctx.allocator.free(revision);
        if (!std.mem.eql(u8, revision, request.expected_revision)) return error.ManifestConflict;

        if (loaded.manifest.manifest_version != 2) return error.ManifestVersionRequired;

        const write_result: WriteResult = if (sourcePreservingOperationsOnly(request.operations)) blk: {
            var source = try ctx.allocator.dupe(u8, loaded.source);
            errdefer ctx.allocator.free(source);
            for (request.operations) |operation| {
                const previous = source;
                source = try applySourcePreservingOperation(ctx.allocator, previous, operation);
                ctx.allocator.free(previous);
            }
            var validated = try moonstone.domain.manifest.MoonstoneToml.parse(ctx.allocator, source);
            defer validated.deinit(ctx.allocator);
            try moonstone.project.manifest_editor.commitSource(ctx.io, source);
            break :blk .{ .source = source, .storage_mode = "source_preserving" };
        } else blk: {
            for (request.operations) |operation| try applyOperation(ctx.allocator, &loaded.manifest, operation);
            break :blk .{
                .source = try moonstone.project.manifest_editor.commit(ctx.allocator, ctx.io, &loaded.manifest),
                .storage_mode = "canonicalized",
            };
        };
        defer ctx.allocator.free(write_result.source);

        try ctx.stdout.writeAll("{\"contract\":\"moonstone:manifest-edit-result:v1\",\"storage_revision\":");
        const updated = try moonstone.domain.manifest_protocol.storageRevision(ctx.allocator, write_result.source);
        defer ctx.allocator.free(updated);
        try std.json.Stringify.value(updated, .{}, ctx.stdout);
        try ctx.stdout.print(",\"applied\":{d},\"storage_mode\":\"{s}\"}}\n", .{ request.operations.len, write_result.storage_mode });
    }
};

fn sourcePreservingOperationsOnly(operations: []const OperationInput) bool {
    if (operations.len == 0) return false;
    for (operations) |operation| {
        if (!std.mem.eql(u8, operation.kind, "set_script") and
            !std.mem.eql(u8, operation.kind, "remove_script") and
            !std.mem.eql(u8, operation.kind, "add_dependency")) return false;
    }
    return true;
}

fn applySourcePreservingOperation(allocator: std.mem.Allocator, source: []const u8, operation: OperationInput) ![]u8 {
    if (std.mem.eql(u8, operation.kind, "add_dependency")) {
        const input = operation.dependency orelse return error.InvalidManifestEditOperation;
        return moonstone.project.manifest_tidy.addDependency(allocator, source, input.name, input.constraint, input.registry, input.role, input.optional);
    }

    const name = operation.name orelse return error.InvalidManifestEditOperation;
    if (std.mem.eql(u8, operation.kind, "set_script")) {
        return moonstone.project.manifest_tidy.setScript(allocator, source, name, operation.command orelse return error.InvalidManifestEditOperation);
    }
    if (std.mem.eql(u8, operation.kind, "remove_script")) return moonstone.project.manifest_tidy.removeScript(allocator, source, name);
    return error.UnsupportedManifestEditOperation;
}

fn applyOperation(allocator: std.mem.Allocator, manifest: *moonstone.domain.manifest.MoonstoneToml, operation: OperationInput) !void {
    if (std.mem.eql(u8, operation.kind, "remove_registry")) {
        const name = operation.name orelse return error.InvalidManifestEditOperation;
        if (manifest.registries.fetchSwapRemove(name)) |entry| {
            allocator.free(entry.key);
            entry.value.deinit(allocator);
            return;
        }
        return error.RegistryNotFound;
    }
    if (std.mem.eql(u8, operation.kind, "set_registry")) {
        const input = operation.registry orelse return error.InvalidManifestEditOperation;
        if (!moonstone.domain.registry_name.isValid(input.name) or isReservedRegistryName(input.name)) return error.InvalidRegistryName;
        if ((input.url == null and input.path == null) or (input.url != null and input.path != null)) return error.InvalidRegistryLocation;
        var replacement = moonstone.domain.manifest.RegistryConfig{
            .resolver = try allocator.dupe(u8, input.resolver),
            .url = if (input.url) |url| try allocator.dupe(u8, url) else null,
            .path = if (input.path) |path| try allocator.dupe(u8, path) else null,
            .priority = input.priority,
        };
        errdefer replacement.deinit(allocator);
        if (manifest.registries.fetchSwapRemove(input.name)) |previous| {
            allocator.free(previous.key);
            previous.value.deinit(allocator);
        }
        try manifest.registries.put(allocator, try allocator.dupe(u8, input.name), replacement);
        return;
    }
    if (std.mem.eql(u8, operation.kind, "set_runtime")) {
        const runtime = operation.runtime orelse return error.InvalidManifestEditOperation;
        allocator.free(manifest.runtime.name);
        allocator.free(manifest.runtime.version);
        allocator.free(manifest.runtime.abi);
        manifest.runtime = .{
            .name = try allocator.dupe(u8, runtime.name),
            .version = try allocator.dupe(u8, runtime.version),
            .abi = try allocator.dupe(u8, runtime.abi),
        };
        return;
    }
    if (std.mem.eql(u8, operation.kind, "remove_dependency")) {
        const name = operation.name orelse return error.InvalidManifestEditOperation;
        for (manifest.dependencies.items, 0..) |*dependency, index| {
            if (std.mem.eql(u8, dependency.name, name)) {
                dependency.deinit(allocator);
                _ = manifest.dependencies.orderedRemove(index);
                return;
            }
        }
        return error.DependencyNotFound;
    }
    if (std.mem.eql(u8, operation.kind, "set_dependency")) {
        const input = operation.dependency orelse return error.InvalidManifestEditOperation;
        var replacement = try buildDependency(allocator, input);
        errdefer replacement.deinit(allocator);
        for (manifest.dependencies.items, 0..) |*dependency, index| {
            if (std.mem.eql(u8, dependency.name, replacement.name)) {
                dependency.deinit(allocator);
                manifest.dependencies.items[index] = replacement;
                return;
            }
        }
        try manifest.dependencies.append(allocator, replacement);
        return;
    }
    if (std.mem.eql(u8, operation.kind, "add_dependency")) {
        const input = operation.dependency orelse return error.InvalidManifestEditOperation;
        for (manifest.dependencies.items) |dependency| if (std.mem.eql(u8, dependency.name, input.name)) return error.DependencyAlreadyExists;
        try manifest.dependencies.append(allocator, try buildDependency(allocator, input));
        return;
    }
    if (std.mem.eql(u8, operation.kind, "remove_script")) {
        const name = operation.name orelse return error.InvalidManifestEditOperation;
        for (manifest.scripts.items, 0..) |*script, index| {
            if (std.mem.eql(u8, script.name, name)) {
                script.deinit(allocator);
                _ = manifest.scripts.orderedRemove(index);
                return;
            }
        }
        return error.ScriptNotFound;
    }
    if (!std.mem.eql(u8, operation.kind, "set_script")) return error.UnsupportedManifestEditOperation;
    const name = operation.name orelse return error.InvalidManifestEditOperation;
    try manifest.setScript(allocator, name, operation.command orelse return error.InvalidManifestEditOperation);
}

fn isReservedRegistryName(name: []const u8) bool {
    const reserved = [_][]const u8{ "moonstone", "rocks", "default", "path", "link", "artifact" };
    for (reserved) |value| if (std.mem.eql(u8, name, value)) return true;
    return false;
}

fn buildDependency(allocator: std.mem.Allocator, input: DependencyInput) !moonstone.domain.manifest.StoreDependency {
    const role = moonstone.domain.manifest.DependencyRole.fromString(input.role) orelse return error.InvalidDependencyRole;
    return .{
        .name = try allocator.dupe(u8, input.name),
        .constraint = try allocator.dupe(u8, input.constraint),
        .registry = if (input.registry) |registry| try allocator.dupe(u8, registry) else null,
        .role = role,
        .optional = input.optional,
    };
}
