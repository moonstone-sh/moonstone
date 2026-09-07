const std = @import("std");
const moonstone = @import("moonstone");
const driver_mod = moonstone.store.driver;
const coordinator_mod = moonstone.resolution.coordinator;
const manifest = moonstone.domain.manifest;
const semver = moonstone.domain.semver;
const registry = moonstone.registry.core;

test "store metadata owns parsed fields and preserves registry and compatibility" {
    const allocator = std.testing.allocator;
    const sm = manifest.StoreManifest{
        .dependencies_complete = true,
        .artifact = .{ .name = "parent", .version = "1.0.0", .kind = .lib, .source_hash = "b3:source", .recipe_hash = "b3:recipe", .artifact_hash = "b3:output", .target = "any" },
        .compat = .{ .runtime_version = "lua@5.4.7", .runtime_artifact_hash = "b3:runtime", .lua_api = "5.4" },
        .dependencies = &.{.{ .name = "child", .constraint = "^2.0.0", .registry = "private", .role = .build }},
    };
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try sm.serialize(allocator, &output.writer);
    var parsed = try manifest.StoreManifest.parse(allocator, output.written());
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.dependencies_complete);
    try std.testing.expectEqualStrings("private", parsed.dependencies[0].registry.?);
    try std.testing.expectEqualStrings("lua@5.4.7", parsed.compat.runtime_version);
    try std.testing.expectEqualStrings("b3:runtime", parsed.compat.runtime_artifact_hash);
    try std.testing.expectEqualStrings("5.4", parsed.compat.lua_api);
    try std.testing.expectEqual(manifest.DependencyRole.build, parsed.dependencies[0].role);
}

test "legacy empty metadata is rejected offline while explicit empty metadata resolves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    var driver = try driver_mod.StoreDriver.init(allocator, ":memory:");
    defer driver.deinit();
    var sm = manifest.StoreManifest{
        .artifact = .{ .name = "legacy", .version = "1.0.0", .kind = .lib, .source_hash = "", .recipe_hash = "", .artifact_hash = "b3:legacy", .target = "any" },
        .origin = .{ .resolver = "moonstone" },
    };
    for ([_]bool{ false, true }) |complete| {
        sm.dependencies_complete = complete;
        var output = std.Io.Writer.Allocating.init(allocator);
        defer output.deinit();
        try sm.serialize(allocator, &output.writer);
        try tmp.dir.writeFile(io, .{ .sub_path = "manifest.toml", .data = output.written() });
        try driver.register_artifact(allocator, sm, path, "manifest.toml");
        var provider: moonstone.resolution.provider.graph_provider.RegistryProvider = undefined;
        provider.init(allocator, io, driver, &.{}, .{ .offline = true }, null, null, null, null, &.{});
        defer provider.deinit();
        if (complete) {
            const versions = try provider.get_provider().getVersions("legacy");
            try std.testing.expectEqual(@as(usize, 1), versions.len);
            const deps = try provider.get_provider().getDependencies("legacy", versions[0]);
            try std.testing.expectEqual(@as(usize, 0), deps.len);
        } else {
            try std.testing.expectError(error.StoreDependencyMetadataIncomplete, provider.get_provider().getVersions("legacy"));
        }
    }
}

test "PubGrub rejects a path dependency conflicting with a direct requirement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "parent");
    try tmp.dir.createDirPath(io, "child");
    try tmp.dir.writeFile(io, .{ .sub_path = "parent/moonstone.toml", .data =
        \\[package]
        \\name = "parent"
        \\version = "1.0.0"
        \\kind = "lib"
        \\[dependencies.runtime]
        \\child = ">=2.0.0"
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "child/moonstone.toml", .data =
        \\[package]
        \\name = "child"
        \\version = "1.0.0"
        \\kind = "lib"
    });
    var driver = try driver_mod.StoreDriver.init(allocator, ":memory:");
    defer driver.deinit();
    const targets = [_]moonstone.resolution.solver.term.Term{
        .{ .name = "parent", .range = try semver.VersionRange.parse(allocator, "*"), .resolver = .path, .registry = try tmp.dir.realPathFileAlloc(io, "parent", allocator) },
        .{ .name = "child", .range = try semver.VersionRange.parse(allocator, "1.0.0"), .resolver = .path, .registry = try tmp.dir.realPathFileAlloc(io, "child", allocator) },
    };
    var provider: moonstone.resolution.provider.graph_provider.RegistryProvider = undefined;
    provider.init(allocator, io, driver, &.{}, .{ .offline = true }, null, null, null, null, &targets);
    defer provider.deinit();
    var solver = moonstone.resolution.solver.pubgrub.Solver.init(allocator, provider.get_provider(), .{});
    defer solver.deinit();
    try std.testing.expectError(error.NoSolution, solver.solve(&targets));
}

test "cached remote candidate cannot satisfy a different exact artifact identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var driver = try driver_mod.StoreDriver.init(allocator, ":memory:");
    defer driver.deinit();
    var provider: moonstone.resolution.provider.graph_provider.RegistryProvider = undefined;
    provider.init(allocator, std.testing.io, driver, &.{}, .{ .offline = true }, null, null, null, null, &.{});
    defer provider.deinit();
    try provider.artifacts.append(allocator, .{
        .name = "lib",
        .version = "1.0.0",
        .kind = .lib,
        .artifact_hash = "b3:source",
        .location = .remote,
        .origin = .{ .moonstone_registry = .{ .url = "", .token = null, .descriptor_path = "", .artifact_idx = 0 } },
        .remote_desc = .{ .package = .{ .name = "lib", .version = "1.0.0", .kind = .lib }, .compat = .{}, .artifact = &.{} },
    });
    try std.testing.expect((try provider.get_artifact(.{ .name = "lib", .version = "1.0.0", .resolver = .moonstone, .artifact_hash = "b3:output" })) == null);
    var exact = (try provider.get_artifact(.{ .name = "lib", .version = "1.0.0", .resolver = .moonstone, .artifact_hash = "b3:source" })).?;
    defer exact.deinit(allocator);
    try std.testing.expectEqualStrings("b3:source", exact.artifact_hash);
}

test "Target Weighting & SQL Query Correctness: full target matrix and ordering" {
    const allocator = std.testing.allocator;
    var driver = try driver_mod.StoreDriver.init(allocator, ":memory:");
    defer driver.deinit();

    // Insert artifacts for package 'testpkg' version 1.0.0 with different targets
    try driver.exec(
        "INSERT INTO artifacts (artifact_hash, name, version, kind, target, lua_abi, runtime, path, manifest_path, lua_api, runtime_artifact_hash, resolver, source, native_compat_required) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
        .{ "b3:hash_other", "testpkg", "1.0.0", "lib", "x86_64-linux", "5.4", "", "/tmp/other", "/tmp/other/manifest.toml", "5.4", "", "moonstone", "", "0" },
    );
    try driver.exec(
        "INSERT INTO artifacts (artifact_hash, name, version, kind, target, lua_abi, runtime, path, manifest_path, lua_api, runtime_artifact_hash, resolver, source, native_compat_required) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
        .{ "b3:hash_empty", "testpkg", "1.0.0", "lib", "", "5.4", "", "/tmp/empty", "/tmp/empty/manifest.toml", "5.4", "", "moonstone", "", "0" },
    );
    try driver.exec(
        "INSERT INTO artifacts (artifact_hash, name, version, kind, target, lua_abi, runtime, path, manifest_path, lua_api, runtime_artifact_hash, resolver, source, native_compat_required) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
        .{ "b3:hash_any", "testpkg", "1.0.0", "lib", "any", "5.4", "", "/tmp/any", "/tmp/any/manifest.toml", "5.4", "", "moonstone", "", "0" },
    );
    try driver.exec(
        "INSERT INTO artifacts (artifact_hash, name, version, kind, target, lua_abi, runtime, path, manifest_path, lua_api, runtime_artifact_hash, resolver, source, native_compat_required) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
        .{ "b3:hash_macos", "testpkg", "1.0.0", "lib", "aarch64-macos", "5.4", "", "/tmp/macos", "/tmp/macos/manifest.toml", "5.4", "", "moonstone", "", "0" },
    );

    // Query with target = 'aarch64-macos'
    const candidates = try driver.findCandidates(.{
        .name = "testpkg",
        .target = "aarch64-macos",
    });
    defer {
        for (candidates) |*c| c.deinit(allocator);
        allocator.free(candidates);
    }

    // Must match exact target, 'any', and '', but NOT 'x86_64-linux'
    try std.testing.expectEqual(@as(usize, 3), candidates.len);
    // 1st: exact target 'aarch64-macos' (CASE WHEN target = ? THEN 1)
    try std.testing.expectEqualStrings("aarch64-macos", candidates[0].target.?);
    try std.testing.expectEqualStrings("b3:hash_macos", candidates[0].artifact_hash);
    // 2nd: 'any' (WHEN target = 'any' THEN 2)
    try std.testing.expectEqualStrings("any", candidates[1].target.?);
    try std.testing.expectEqualStrings("b3:hash_any", candidates[1].artifact_hash);
    // 3rd: '' (ELSE 3)
    try std.testing.expectEqualStrings("", candidates[2].target.?);
    try std.testing.expectEqualStrings("b3:hash_empty", candidates[2].artifact_hash);
}

test "Target Weighting & SQL Query Correctness: target == null query" {
    const allocator = std.testing.allocator;
    var driver = try driver_mod.StoreDriver.init(allocator, ":memory:");
    defer driver.deinit();

    try driver.exec(
        "INSERT INTO artifacts (artifact_hash, name, version, kind, target, lua_abi, runtime, path, manifest_path, lua_api, runtime_artifact_hash, resolver, source, native_compat_required) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
        .{ "b3:hash_v1", "pkg_notarget", "1.0.0", "lib", "any", "5.4", "", "/tmp/v1", "/tmp/v1/manifest.toml", "5.4", "", "moonstone", "", "0" },
    );
    try driver.exec(
        "INSERT INTO artifacts (artifact_hash, name, version, kind, target, lua_abi, runtime, path, manifest_path, lua_api, runtime_artifact_hash, resolver, source, native_compat_required) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
        .{ "b3:hash_v2", "pkg_notarget", "2.0.0", "lib", "any", "5.4", "", "/tmp/v2", "/tmp/v2/manifest.toml", "5.4", "", "moonstone", "", "0" },
    );

    const candidates = try driver.findCandidates(.{
        .name = "pkg_notarget",
        .target = null,
    });
    defer {
        for (candidates) |*c| c.deinit(allocator);
        allocator.free(candidates);
    }

    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    // Ordered by version DESC
    try std.testing.expectEqualStrings("2.0.0", candidates[0].version);
    try std.testing.expectEqualStrings("1.0.0", candidates[1].version);
}

test "Target Weighting & SQL Query Correctness: all query parameters bound simultaneously" {
    const allocator = std.testing.allocator;
    var driver = try driver_mod.StoreDriver.init(allocator, ":memory:");
    defer driver.deinit();

    try driver.exec(
        "INSERT INTO artifacts (artifact_hash, name, version, kind, target, lua_abi, runtime, path, manifest_path, lua_api, runtime_artifact_hash, resolver, source, native_compat_required, recipe_hash) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
        .{ "b3:full_match", "FullPkg", "1.5.0", "lib", "x86_64-linux", "5.4", "5.4.7", "/tmp/full", "/tmp/full/manifest.toml", "5.4", "b3:interp_hash", "rocks", "https://luarocks.org", "1", "b3:recipe_123" },
    );

    const candidates = try driver.findCandidates(.{
        .name = "fullpkg",
        .case_insensitive_name = true,
        .resolver = "rocks",
        .kind = .lib,
        .target = "x86_64-linux",
        .lua_abi = "5.4",
        .lua_api = "5.4",
        .runtime = "5.4.7",
        .runtime_artifact_hash = "b3:interp_hash",
        .native_compat_required = true,
        .recipe_hash = "b3:recipe_123",
    });
    defer {
        for (candidates) |*c| c.deinit(allocator);
        allocator.free(candidates);
    }

    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("b3:full_match", candidates[0].artifact_hash);
    try std.testing.expectEqualStrings("FullPkg", candidates[0].name);
    try std.testing.expectEqualStrings("b3:interp_hash", candidates[0].runtime_artifact_hash.?);
    try std.testing.expectEqualStrings("b3:recipe_123", candidates[0].recipe_hash.?);
}

fn writeCandidateManifest(dir: std.Io.Dir, path: []const u8, name: []const u8, version: []const u8, hash: []const u8, resolver: []const u8) !void {
    const allocator = std.testing.allocator;
    const sm = moonstone.domain.manifest.StoreManifest{
        .dependencies_complete = true,
        .artifact = .{ .name = name, .version = version, .kind = .lib, .source_hash = "", .recipe_hash = "", .artifact_hash = hash, .target = "any" },
        .origin = .{ .resolver = resolver },
    };
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try sm.serialize(allocator, &output.writer);
    const manifest_path = try std.fs.path.join(allocator, &.{ path, "manifest.toml" });
    defer allocator.free(manifest_path);
    try dir.writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = output.written() });
}

test "SemVer Maximization in Store Resolution: numerical ordering 1.10.0 vs 1.9.0" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var driver = try driver_mod.StoreDriver.init(allocator, ":memory:");
    defer driver.deinit();

    const versions = [_][]const u8{ "1.1.0", "1.2.0", "1.9.0", "1.10.0", "1.10.1" };
    for (versions) |v| {
        const dir_name = try std.fmt.allocPrint(allocator, "pkg_{s}", .{v});
        defer allocator.free(dir_name);
        try tmp.dir.createDirPath(io, dir_name);
        const real_path = try tmp.dir.realPathFileAlloc(io, dir_name, allocator);
        defer allocator.free(real_path);

        const art_hash = try std.fmt.allocPrint(allocator, "b3:hash_{s}", .{v});
        defer allocator.free(art_hash);
        try writeCandidateManifest(tmp.dir, dir_name, "numsemver", v, art_hash, "moonstone");

        try driver.exec(
            "INSERT INTO artifacts (artifact_hash, name, version, kind, target, lua_abi, runtime, path, manifest_path, lua_api, runtime_artifact_hash, resolver, source, native_compat_required) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
            .{ art_hash, "numsemver", v, "lib", "any", "5.4", "", real_path, "/tmp/manifest.toml", "5.4", "", "moonstone", "", "0" },
        );
    }

    const coordinator = coordinator_mod.Coordinator.init(allocator, io);

    // 1. Query with ^1.0.0 -> must maximize to 1.10.1 (not 1.9.0 which is lexicographically higher than 1.10.1)
    {
        var resolved = try coordinator.tryResolveFromStore("numsemver", "^1.0.0", .moonstone, driver, .{}, &.{});
        try std.testing.expect(resolved != null);
        defer if (resolved) |*c| c.deinit(allocator);
        try std.testing.expectEqualStrings("1.10.1", resolved.?.version);
    }

    // 2. Query with <1.10.0 -> must maximize to 1.9.0
    {
        var resolved = try coordinator.tryResolveFromStore("numsemver", "<1.10.0", .moonstone, driver, .{}, &.{});
        try std.testing.expect(resolved != null);
        defer if (resolved) |*c| c.deinit(allocator);
        try std.testing.expectEqualStrings("1.9.0", resolved.?.version);
    }
}

test "SemVer Maximization in Store Resolution: LuaRocks revisions 2.10-2 vs 2.10-1 vs 2.8-1" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var driver = try driver_mod.StoreDriver.init(allocator, ":memory:");
    defer driver.deinit();

    const rock_versions = [_][]const u8{ "2.8-1", "2.9-1", "2.10-1", "2.10-2" };
    for (rock_versions) |v| {
        const dir_name = try std.fmt.allocPrint(allocator, "rock_{s}", .{v});
        defer allocator.free(dir_name);
        try tmp.dir.createDirPath(io, dir_name);
        const real_path = try tmp.dir.realPathFileAlloc(io, dir_name, allocator);
        defer allocator.free(real_path);

        const art_hash = try std.fmt.allocPrint(allocator, "b3:rock_{s}", .{v});
        defer allocator.free(art_hash);
        try writeCandidateManifest(tmp.dir, dir_name, "rockpkg", v, art_hash, "rocks");

        try driver.exec(
            "INSERT INTO artifacts (artifact_hash, name, version, kind, target, lua_abi, runtime, path, manifest_path, lua_api, runtime_artifact_hash, resolver, source, native_compat_required) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
            .{ art_hash, "rockpkg", v, "lib", "any", "5.4", "", real_path, "/tmp/manifest.toml", "5.4", "", "rocks", "https://luarocks.org", "0" },
        );
    }

    const coordinator = coordinator_mod.Coordinator.init(allocator, io);

    // Compare upstream versions numerically, then compare rock revisions.
    var resolved = try coordinator.tryResolveFromStore("rockpkg", ">= 2.0, < 3.0", .rocks, driver, .{}, &.{});
    try std.testing.expect(resolved != null);
    defer if (resolved) |*c| c.deinit(allocator);
    try std.testing.expectEqualStrings("2.10-2", resolved.?.version);
}

test "SemVer Maximization in Store Resolution: prunes missing disk paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var driver = try driver_mod.StoreDriver.init(allocator, ":memory:");
    defer driver.deinit();

    // Insert artifact with non-existent path
    try driver.exec(
        "INSERT INTO artifacts (artifact_hash, name, version, kind, target, lua_abi, runtime, path, manifest_path, lua_api, runtime_artifact_hash, resolver, source, native_compat_required) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
        .{ "b3:stale_art", "stalepkg", "1.0.0", "lib", "any", "5.4", "", "/nonexistent/path/on/disk", "/nonexistent/path/on/disk/manifest.toml", "5.4", "", "moonstone", "", "0" },
    );

    const coordinator = coordinator_mod.Coordinator.init(allocator, io);
    const resolved = try coordinator.tryResolveFromStore("stalepkg", "*", .moonstone, driver, .{}, &.{});
    try std.testing.expect(resolved == null);

    // Verify stale entry was purged from database
    const has_it = try driver.has_artifact("b3:stale_art");
    try std.testing.expect(!has_it);
}

test "Store Candidate Registry Dependency Validation: filters unknown registries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var driver = try driver_mod.StoreDriver.init(allocator, ":memory:");
    defer driver.deinit();

    // Create candidate directory with manifest.toml containing dependencies from custom registry
    try tmp.dir.createDirPath(io, "cand_dir");
    const manifest_content =
        \\dependencies_complete = true
        \\[artifact]
        \\name = "regdep_pkg"
        \\version = "1.0.0"
        \\kind = "lib"
        \\source_hash = "b3:src"
        \\recipe_hash = "b3:recipe"
        \\artifact_hash = "b3:cand_hash"
        \\target = "any"
        \\
        \\[origin]
        \\resolver = "moonstone"
        \\source = "https://registry.moonstone.sh"
        \\
        \\[compat]
        \\lua_abi = "5.4"
        \\runtime_version = "5.4.7"
        \\lua_api = "5.4"
        \\runtime_artifact_hash = ""
        \\
        \\[[dependencies]]
        \\name = "internal_helper"
        \\constraint = "1.0.0"
        \\registry = "enterprise_internal"
        \\
        \\[[dependencies]]
        \\name = "luasocket"
        \\constraint = "3.1.0-1"
        \\registry = "rocks"
        \\
        \\[[dependencies]]
        \\name = "moonstone/lua"
        \\constraint = "5.4.7"
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "cand_dir/manifest.toml", .data = manifest_content });
    const cand_path = try tmp.dir.realPathFileAlloc(io, "cand_dir", allocator);
    defer allocator.free(cand_path);

    try driver.exec(
        "INSERT INTO artifacts (artifact_hash, name, version, kind, target, lua_abi, runtime, path, manifest_path, lua_api, runtime_artifact_hash, resolver, source, native_compat_required) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
        .{ "b3:cand_hash", "regdep_pkg", "1.0.0", "lib", "any", "5.4", "", cand_path, "/tmp/manifest.toml", "5.4", "", "moonstone", "", "0" },
    );

    const coordinator = coordinator_mod.Coordinator.init(allocator, io);

    // 1. Without enterprise_internal in configured registries -> should reject candidate
    const empty_registries: []const registry.ResolvedRegistry = &.{};
    const resolved_rejected = try coordinator.tryResolveFromStore("regdep_pkg", "*", .moonstone, driver, .{}, empty_registries);
    try std.testing.expect(resolved_rejected == null);

    // 2. With enterprise_internal in configured registries -> should accept candidate
    const configured_registries = [_]registry.ResolvedRegistry{
        .{
            .name = "enterprise_internal",
            .url = "https://internal.corp/registry",
            .resolver = "moonstone",
            .token = null,
            .priority = 1,
        },
    };
    var resolved_accepted = try coordinator.tryResolveFromStore("regdep_pkg", "*", .moonstone, driver, .{}, &configured_registries);
    try std.testing.expect(resolved_accepted != null);
    defer if (resolved_accepted) |*c| c.deinit(allocator);
    try std.testing.expectEqualStrings("regdep_pkg", resolved_accepted.?.name);
}

test "Read-Only SQLite Concurrency: multi-threaded read stress" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_file_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(db_file_path);
    const full_db_path = try std.fs.path.join(allocator, &.{ db_file_path, "store.db" });
    defer allocator.free(full_db_path);
    const full_db_path_z = try allocator.dupeZ(u8, full_db_path);
    defer allocator.free(full_db_path_z);

    // Initialize writable database and seed data
    {
        var rw_driver = try driver_mod.StoreDriver.init(allocator, full_db_path_z);
        defer rw_driver.deinit();

        for (0..20) |i| {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "concurrent_pkg_{d}", .{i});
            var hash_buf: [32]u8 = undefined;
            const hash = try std.fmt.bufPrint(&hash_buf, "b3:hash_{d}", .{i});

            try rw_driver.exec(
                "INSERT INTO artifacts (artifact_hash, name, version, kind, target, lua_abi, runtime, path, manifest_path, lua_api, runtime_artifact_hash, resolver, source, native_compat_required) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
                .{ hash, name, "1.0.0", "lib", "any", "5.4", "", "/tmp/path", "/tmp/manifest.toml", "5.4", "", "moonstone", "", "0" },
            );
        }
    }

    // Spawn 8 threads each using initReadOnly
    const Worker = struct {
        path_z: [:0]const u8,

        fn run(self: @This()) void {
            const thread_allocator = std.heap.page_allocator;
            var ro_driver = driver_mod.StoreDriver.initReadOnly(thread_allocator, self.path_z) catch @panic("initReadOnly failed");
            defer ro_driver.deinit();

            for (0..50) |i| {
                const pkg_idx = i % 20;
                var name_buf: [32]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buf, "concurrent_pkg_{d}", .{pkg_idx}) catch unreachable;
                var hash_buf: [32]u8 = undefined;
                const hash = std.fmt.bufPrint(&hash_buf, "b3:hash_{d}", .{pkg_idx}) catch unreachable;

                const candidates = ro_driver.findCandidates(.{ .name = name }) catch @panic("findCandidates failed");
                defer {
                    for (candidates) |*c| c.deinit(thread_allocator);
                    thread_allocator.free(candidates);
                }
                if (candidates.len != 1) @panic("Expected 1 candidate");

                var cand_by_hash = ro_driver.get_candidate_by_hash(hash) catch @panic("get_candidate_by_hash failed");
                if (cand_by_hash) |*c| {
                    defer c.deinit(thread_allocator);
                } else {
                    @panic("Candidate by hash missing");
                }
            }
        }
    };

    const thread_count = 8;
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{Worker{ .path_z = full_db_path_z }});
    }
    for (threads) |t| {
        t.join();
    }
}

test "Read-Only SQLite Invariant: mutations fail cleanly" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_file_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(db_file_path);
    const full_db_path = try std.fs.path.join(allocator, &.{ db_file_path, "readonly_test.db" });
    defer allocator.free(full_db_path);
    const full_db_path_z = try allocator.dupeZ(u8, full_db_path);
    defer allocator.free(full_db_path_z);

    // Create DB with write driver
    {
        var rw_driver = try driver_mod.StoreDriver.init(allocator, full_db_path_z);
        rw_driver.deinit();
    }

    // Open read-only
    var ro_driver = try driver_mod.StoreDriver.initReadOnly(allocator, full_db_path_z);
    defer ro_driver.deinit();

    // Attempting DELETE should return SQLiteReadOnly error
    const res = ro_driver.delete_artifact("b3:any");
    try std.testing.expectError(error.SQLiteReadOnly, res);
}

test "Memory Safety & Error Handling: delete_artifact cleans all 12 tables" {
    const allocator = std.testing.allocator;
    var driver = try driver_mod.StoreDriver.init(allocator, ":memory:");
    defer driver.deinit();

    const art_hash = "b3:cascade_test";

    // Insert into artifacts
    try driver.exec(
        "INSERT INTO artifacts (artifact_hash, name, version, kind, target, lua_abi, runtime, path, manifest_path, lua_api, runtime_artifact_hash, resolver, source, native_compat_required) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
        .{ art_hash, "cascadepkg", "1.0.0", "lib", "any", "5.4", "", "/tmp/path", "/tmp/manifest.toml", "5.4", "", "moonstone", "", "0" },
    );
    // Insert into provides tables
    try driver.exec("INSERT INTO provides_bin (artifact_hash, name, path, entry_point) VALUES (?, ?, ?, ?);", .{ art_hash, "bin1", "bin/bin1", "main" });
    try driver.exec("INSERT INTO provides_bin_lua (artifact_hash, name, path, entry_point) VALUES (?, ?, ?, ?);", .{ art_hash, "binlua1", "bin/binlua1", "main" });
    try driver.exec("INSERT INTO provides_headers (artifact_hash, name, path) VALUES (?, ?, ?);", .{ art_hash, "h1", "include/h1.h" });
    try driver.exec("INSERT INTO provides_native_lib (artifact_hash, name, path, linkage) VALUES (?, ?, ?, ?);", .{ art_hash, "lib1", "lib/lib1.so", "dynamic" });
    try driver.exec("INSERT INTO provides_lua_module (artifact_hash, name, path) VALUES (?, ?, ?);", .{ art_hash, "mod1", "lua/mod1.lua" });
    try driver.exec("INSERT INTO provides_lua_cmodule (artifact_hash, name, path) VALUES (?, ?, ?);", .{ art_hash, "cmod1", "lua/cmod1.so" });
    try driver.exec("INSERT INTO provides_script (artifact_hash, name, path, entry_point) VALUES (?, ?, ?, ?);", .{ art_hash, "script1", "scripts/s1", "run" });
    try driver.exec("INSERT INTO provides_asset (artifact_hash, name, path) VALUES (?, ?, ?);", .{ art_hash, "asset1", "assets/a1" });
    try driver.exec("INSERT INTO provides_ballad_plugin (artifact_hash, name, path, entry_point, module) VALUES (?, ?, ?, ?, ?);", .{ art_hash, "plugin1", "plugins/p1", "ep", "mod" });
    try driver.exec("INSERT INTO provides_runtime (artifact_hash, name, version, abi) VALUES (?, ?, ?, ?);", .{ art_hash, "lua", "5.4.7", "5.4" });
    try driver.exec("INSERT INTO artifact_name_trigrams (artifact_hash, trigram) VALUES (?, ?);", .{ art_hash, "cas" });

    // Verify provisions before deletion
    const provs = try driver.get_provisions(art_hash);
    defer {
        for (provs.bins) |p| p.deinit(allocator);
        allocator.free(provs.bins);
        for (provs.bin_luas) |p| p.deinit(allocator);
        allocator.free(provs.bin_luas);
        for (provs.headers) |p| p.deinit(allocator);
        allocator.free(provs.headers);
        for (provs.libs) |p| p.deinit(allocator);
        allocator.free(provs.libs);
        for (provs.lua_modules) |p| p.deinit(allocator);
        allocator.free(provs.lua_modules);
        for (provs.lua_cmodules) |p| p.deinit(allocator);
        allocator.free(provs.lua_cmodules);
        for (provs.scripts) |p| p.deinit(allocator);
        allocator.free(provs.scripts);
        for (provs.assets) |p| p.deinit(allocator);
        allocator.free(provs.assets);
        for (provs.ballad_plugins) |p| p.deinit(allocator);
        allocator.free(provs.ballad_plugins);
    }
    try std.testing.expectEqual(@as(usize, 1), provs.bins.len);
    try std.testing.expectEqual(@as(usize, 1), provs.libs.len);
    try std.testing.expectEqual(@as(usize, 1), provs.lua_modules.len);

    // Delete artifact
    try driver.delete_artifact(art_hash);

    // Verify all tables are empty for this hash
    try std.testing.expect(!try driver.has_artifact(art_hash));
    const provs_after = try driver.get_provisions(art_hash);
    defer {
        allocator.free(provs_after.bins);
        allocator.free(provs_after.bin_luas);
        allocator.free(provs_after.headers);
        allocator.free(provs_after.libs);
        allocator.free(provs_after.lua_modules);
        allocator.free(provs_after.lua_cmodules);
        allocator.free(provs_after.scripts);
        allocator.free(provs_after.assets);
        allocator.free(provs_after.ballad_plugins);
    }
    try std.testing.expectEqual(@as(usize, 0), provs_after.bins.len);
    try std.testing.expectEqual(@as(usize, 0), provs_after.bin_luas.len);
    try std.testing.expectEqual(@as(usize, 0), provs_after.headers.len);
    try std.testing.expectEqual(@as(usize, 0), provs_after.libs.len);
    try std.testing.expectEqual(@as(usize, 0), provs_after.lua_modules.len);
    try std.testing.expectEqual(@as(usize, 0), provs_after.lua_cmodules.len);
    try std.testing.expectEqual(@as(usize, 0), provs_after.scripts.len);
    try std.testing.expectEqual(@as(usize, 0), provs_after.assets.len);
    try std.testing.expectEqual(@as(usize, 0), provs_after.ballad_plugins.len);
}
