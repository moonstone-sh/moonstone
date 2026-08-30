const std = @import("std");
const lockfile = @import("../domain/lockfile.zig");
const driver_mod = @import("../store/driver.zig");
const executable = @import("../platform/executable.zig");
const platform_target = @import("../platform/target.zig");

/// Provenance is deliberately limited to Moonstone-owned state. A result can
/// never describe a PATH executable, a registry URL, or an unpinned live link.
pub const Source = enum { project, global, store };

pub const Result = struct {
    path: []const u8,
    version: []const u8,
    digest: []const u8,
    source: Source,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.version);
        allocator.free(self.digest);
    }
};

pub const StoreLookup = union(enum) {
    found: Result,
    missing,
    target_mismatch,
    artifact_missing,
    ambiguous,
};

pub fn validateExecutableName(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidToolProvisionName;
    if (std.fs.path.isAbsolute(name) or std.mem.indexOfAny(u8, name, "/\\\x00") != null) return error.InvalidToolProvisionName;
    if (name.len >= 2 and std.ascii.isAlphabetic(name[0]) and name[1] == ':') return error.InvalidToolProvisionName;
}

/// Resolve from a synchronized project/global-tools environment. The scope
/// marker and lock entry must agree with a locally indexed CAS artifact; this
/// intentionally excludes mutable path/link dependencies.
pub fn resolveFromRealizedEnvironment(
    allocator: std.mem.Allocator,
    io: std.Io,
    index: driver_mod.StoreDriver,
    project_root: []const u8,
    executable_name: []const u8,
    target: []const u8,
    source: Source,
) !?Result {
    try validateExecutableName(executable_name);
    if (!platform_target.isHost(target)) return null;

    const scopes = try realizedScopes(allocator, io, project_root, executable_name);
    if (!scopes.tool and !scopes.helper) return null;

    const lock_path = try std.fs.path.join(allocator, &.{ project_root, "moonstone.lock" });
    defer allocator.free(lock_path);
    const raw = std.Io.Dir.cwd().readFileAlloc(io, lock_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return error.RealizedToolEnvironmentMissingLockfile;
        return err;
    };
    defer allocator.free(raw);
    var lock = try lockfile.LockFile.parse(allocator, raw);
    defer lock.deinit();

    var found_named = false;
    var found_target = false;
    var missing_artifact = false;
    var resolved: ?Result = null;
    errdefer if (resolved) |*result| result.deinit(allocator);

    for (lock.packages.items) |entry| {
        if (!scopeRoleMatches(scopes, entry.roles)) continue;
        if (entry.artifact_hash.len == 0 or !std.mem.startsWith(u8, entry.artifact_hash, "b3:")) continue;

        var candidate = try index.get_candidate_by_hash(entry.artifact_hash) orelse {
            missing_artifact = true;
            continue;
        };
        defer candidate.deinit(allocator);
        const artifact_target = try index.get_artifact_target(entry.artifact_hash) orelse {
            missing_artifact = true;
            continue;
        };
        defer allocator.free(artifact_target);
        const provision = try provisionForCandidate(allocator, io, index, candidate, artifact_target, executable_name, target, source) orelse continue;
        if (provision.target_state == .mismatch) {
            found_named = true;
            continue;
        }
        found_named = true;
        found_target = true;
        if (provision.result) |result| {
            if (resolved != null) {
                var current = result;
                current.deinit(allocator);
                var prior = resolved.?;
                prior.deinit(allocator);
                return error.AmbiguousToolProvision;
            }
            resolved = result;
        } else {
            missing_artifact = true;
        }
    }
    if (resolved) |result| return result;
    if (missing_artifact) return error.ToolProvisionArtifactMissing;
    if (found_named and !found_target) return error.ToolProvisionTargetMismatch;
    return error.RealizedToolEnvironmentProvisionMissing;
}

/// Resolve only from already indexed and materialized CAS artifacts. It never
/// contacts a registry, invokes the solver, writes the store, or edits a lock.
pub fn resolveFromStore(
    allocator: std.mem.Allocator,
    io: std.Io,
    index: driver_mod.StoreDriver,
    executable_name: []const u8,
    target: []const u8,
) !StoreLookup {
    try validateExecutableName(executable_name);
    const candidates = try index.find_candidates_providing_bin(executable_name);
    defer {
        for (candidates) |candidate| {
            var mutable_candidate = candidate;
            mutable_candidate.deinit(allocator);
        }
        allocator.free(candidates);
    }

    var target_mismatch = false;
    var artifact_missing = false;
    var resolved: ?Result = null;
    errdefer if (resolved) |*result| result.deinit(allocator);
    for (candidates) |candidate| {
        const provision = try provisionForCandidate(allocator, io, index, candidate, candidate.target, executable_name, target, .store) orelse continue;
        if (provision.target_state == .mismatch) {
            target_mismatch = true;
            continue;
        }
        if (provision.result) |result| {
            if (resolved != null) {
                var current = result;
                current.deinit(allocator);
                var prior = resolved.?;
                prior.deinit(allocator);
                return .ambiguous;
            }
            resolved = result;
        } else {
            artifact_missing = true;
        }
    }
    if (resolved) |result| return .{ .found = result };
    if (artifact_missing) return .artifact_missing;
    if (target_mismatch) return .target_mismatch;
    return .missing;
}

const Scopes = struct { tool: bool = false, helper: bool = false };
const TargetState = enum { matching, mismatch };
const ProvisionLookup = struct {
    target_state: TargetState,
    result: ?Result = null,
};

fn realizedScopes(allocator: std.mem.Allocator, io: std.Io, root: []const u8, executable_name: []const u8) !Scopes {
    var scopes = Scopes{};
    inline for (.{ .{ "bin-runtime", "tool" }, .{ "bin-helper", "helper" } }) |candidate| {
        const path = try std.fs.path.join(allocator, &.{ root, ".moonstone", "env", candidate[0], executable_name, "env.toml" });
        defer allocator.free(path);
        if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
            @field(scopes, candidate[1]) = true;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }
    }
    return scopes;
}

fn scopeRoleMatches(scopes: Scopes, roles: []const []const u8) bool {
    for (roles) |role| {
        if (scopes.tool and std.mem.eql(u8, role, "tool")) return true;
        if (scopes.helper and std.mem.eql(u8, role, "helper")) return true;
    }
    return false;
}

fn targetMatches(artifact_target: []const u8, requested_target: []const u8) bool {
    if (std.mem.eql(u8, artifact_target, requested_target) or std.mem.eql(u8, artifact_target, "any")) return true;
    return std.mem.eql(u8, artifact_target, "native") and platform_target.isHost(requested_target);
}

fn validProvisionPath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.indexOfScalar(u8, part, '\\') != null) return false;
    }
    return true;
}

fn provisionForCandidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    index: driver_mod.StoreDriver,
    candidate: anytype,
    artifact_target: []const u8,
    executable_name: []const u8,
    target: []const u8,
    source: Source,
) !?ProvisionLookup {
    const provisions = try index.get_provisions(candidate.artifact_hash);
    defer deinitProvisions(allocator, provisions);

    inline for (.{ provisions.bins, provisions.bin_luas }) |items| {
        for (items) |provision| {
            if (!std.mem.eql(u8, provision.name, executable_name)) continue;
            if (!targetMatches(artifact_target, target)) return .{ .target_state = .mismatch };
            if (!validProvisionPath(provision.path) or !executable.targetExecutableNameMatches(target, executable_name, std.fs.path.basename(provision.path))) return error.InvalidToolProvision;

            const relative_dir = std.fs.path.dirname(provision.path) orelse return error.InvalidToolProvision;
            const directory = try std.fs.path.join(allocator, &.{ candidate.path, "files", relative_dir });
            defer allocator.free(directory);
            const expected = try std.fs.path.join(allocator, &.{ candidate.path, "files", provision.path });
            errdefer allocator.free(expected);
            const actual = try executable.resolveInDirectoryForTarget(allocator, io, directory, executable_name, target) orelse {
                allocator.free(expected);
                return .{ .target_state = .matching };
            };
            defer allocator.free(actual);
            if (!sameTargetPath(target, actual, expected)) {
                allocator.free(expected);
                return error.InvalidToolProvision;
            }
            const version = try allocator.dupe(u8, candidate.version);
            errdefer allocator.free(version);
            const digest = try allocator.dupe(u8, candidate.artifact_hash);
            errdefer allocator.free(digest);
            return .{ .target_state = .matching, .result = .{
                .path = expected,
                .version = version,
                .digest = digest,
                .source = source,
            } };
        }
    }
    return null;
}

fn sameTargetPath(target: []const u8, left: []const u8, right: []const u8) bool {
    if (std.mem.indexOf(u8, target, "-windows-") != null) return std.ascii.eqlIgnoreCase(left, right);
    return std.mem.eql(u8, left, right);
}

fn deinitProvisions(allocator: std.mem.Allocator, provisions: anytype) void {
    inline for (.{ provisions.bins, provisions.bin_luas, provisions.headers, provisions.libs, provisions.lua_modules, provisions.lua_cmodules, provisions.scripts, provisions.assets, provisions.ballad_plugins }) |items| {
        for (items) |item| {
            var mutable_item = item;
            mutable_item.deinit(allocator);
        }
    }
    inline for (.{ provisions.bins, provisions.bin_luas, provisions.headers, provisions.libs, provisions.lua_modules, provisions.lua_cmodules, provisions.scripts, provisions.assets, provisions.ballad_plugins }) |items| allocator.free(items);
}

fn insertFixtureArtifact(driver: driver_mod.StoreDriver, root: []const u8, digest: []const u8, version: []const u8, target: []const u8, executable_name: []const u8, executable_path: []const u8) !void {
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ root, "manifest.toml" });
    defer std.testing.allocator.free(manifest_path);
    try driver.exec(
        "INSERT INTO artifacts (artifact_hash, name, version, kind, target, lua_abi, runtime, path, manifest_path, lua_api, runtime_artifact_hash, resolver, source, native_compat_required) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
        .{ digest, "fixture-tool", version, "bin", target, "lua54", "lua@5.4", root, manifest_path, "lua54", "", "fixture", "fixture", 0 },
    );
    try driver.exec("INSERT INTO provides_bin (artifact_hash, name, path) VALUES (?, ?, ?);", .{ digest, executable_name, executable_path });
}

fn createFixtureExecutable(root: []const u8, relative_path: []const u8) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const absolute = try std.fs.path.join(allocator, &.{ root, "files", relative_path });
    defer allocator.free(absolute);
    if (std.fs.path.dirname(absolute)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    const file = try std.Io.Dir.cwd().createFile(io, absolute, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "fixture\n");
}

test "local CAS tool lookup returns the declared target executable" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var index = try driver_mod.StoreDriver.init(allocator, ":memory:");
    defer index.deinit();
    const target = platform_target.hostTargetLiteral();
    try createFixtureExecutable(root, "bin/tool");
    try insertFixtureArtifact(index, root, "b3:fixture-one", "1.2.3", target, "tool", "bin/tool");

    var result = switch (try resolveFromStore(allocator, io, index, "tool", target)) {
        .found => |found| found,
        else => return error.TestExpectedEqual,
    };
    defer result.deinit(allocator);
    try std.testing.expectEqual(Source.store, result.source);
    try std.testing.expectEqualStrings("1.2.3", result.version);
    try std.testing.expectEqualStrings("b3:fixture-one", result.digest);
    try std.testing.expect(std.mem.endsWith(u8, result.path, "/files/bin/tool"));
}

test "local CAS tool lookup distinguishes target mismatch, missing payload, and ambiguity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var index = try driver_mod.StoreDriver.init(allocator, ":memory:");
    defer index.deinit();
    const target = platform_target.hostTargetLiteral();

    const foreign_target = if (std.mem.indexOf(u8, target, "-windows-") != null) "x86_64-linux-gnu" else "x86_64-windows-gnu";
    try insertFixtureArtifact(index, root, "b3:foreign", "1.0.0", foreign_target, "foreign-tool", "bin/foreign-tool.exe");
    try std.testing.expectEqual(StoreLookup.target_mismatch, try resolveFromStore(allocator, io, index, "foreign-tool", target));

    try insertFixtureArtifact(index, root, "b3:missing", "1.0.0", target, "missing-tool", "bin/missing-tool");
    try std.testing.expectEqual(StoreLookup.artifact_missing, try resolveFromStore(allocator, io, index, "missing-tool", target));

    try createFixtureExecutable(root, "bin/ambiguous-tool");
    try insertFixtureArtifact(index, root, "b3:ambiguous-one", "1.0.0", target, "ambiguous-tool", "bin/ambiguous-tool");
    try insertFixtureArtifact(index, root, "b3:ambiguous-two", "2.0.0", target, "ambiguous-tool", "bin/ambiguous-tool");
    try std.testing.expectEqual(StoreLookup.ambiguous, try resolveFromStore(allocator, io, index, "ambiguous-tool", target));
}

test "realized tool scope uses its locked CAS owner" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const target = platform_target.hostTargetLiteral();
    var index = try driver_mod.StoreDriver.init(allocator, ":memory:");
    defer index.deinit();

    try createFixtureExecutable(root, "bin/tool");
    try insertFixtureArtifact(index, root, "b3:locked", "1.0.0", target, "tool", "bin/tool");
    try insertFixtureArtifact(index, root, "b3:other", "2.0.0", target, "tool", "bin/tool");
    const scope = try std.fs.path.join(allocator, &.{ root, ".moonstone", "env", "bin-runtime", "tool" });
    defer allocator.free(scope);
    try std.Io.Dir.cwd().createDirPath(io, scope);
    const scope_toml = try std.fs.path.join(allocator, &.{ scope, "env.toml" });
    defer allocator.free(scope_toml);
    const scope_file = try std.Io.Dir.cwd().createFile(io, scope_toml, .{});
    try scope_file.writeStreamingAll(io, "[env]\npath_prepend = []\n");
    scope_file.close(io);

    const lock_path = try std.fs.path.join(allocator, &.{ root, "moonstone.lock" });
    defer allocator.free(lock_path);
    const lock_file = try std.Io.Dir.cwd().createFile(io, lock_path, .{});
    try lock_file.writeStreamingAll(io,
        \\lockfile_version = 2
        \\
        \\[[package]]
        \\name = "fixture-tool"
        \\version = "1.0.0"
        \\kind = "bin"
        \\source_hash = "b3:source"
        \\recipe_hash = "b3:recipe"
        \\artifact_hash = "b3:locked"
        \\runtime = "lua@5.4"
        \\lua_abi = "lua54"
        \\
    );
    const target_line = try std.fmt.allocPrint(allocator, "target = \"{s}\"\nroles = [\"tool\"]\n", .{target});
    defer allocator.free(target_line);
    try lock_file.writeStreamingAll(io, target_line);
    lock_file.close(io);

    var result = (try resolveFromRealizedEnvironment(allocator, io, index, root, "tool", target, .project)).?;
    defer result.deinit(allocator);
    try std.testing.expectEqual(Source.project, result.source);
    try std.testing.expectEqualStrings("1.0.0", result.version);
    try std.testing.expectEqualStrings("b3:locked", result.digest);
}

test "tool lookup rejects path-like executable names" {
    try std.testing.expectError(error.InvalidToolProvisionName, validateExecutableName("../tool"));
    try std.testing.expectError(error.InvalidToolProvisionName, validateExecutableName("bin/tool"));
    try std.testing.expectError(error.InvalidToolProvisionName, validateExecutableName(""));
}
