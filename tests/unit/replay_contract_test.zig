const std = @import("std");
const moonstone = @import("moonstone");
const replay_mod = moonstone.domain.replay_contract;
const lockfile_mod = moonstone.domain.lockfile;
const plan_mod = moonstone.materialization.plan;
const executor_mod = moonstone.materialization.executor;
const host_resolver = moonstone.tools.host_resolver;

test "replay contract v2 lockfile parse and roundtrip" {
    const allocator = std.testing.allocator;
    const content =
        \\lockfile_version = 2
        \\
        \\[[package]]
        \\name = "zig-native-demo"
        \\version = "1.0.0"
        \\kind = "lib"
        \\source_hash = "b3:src123"
        \\recipe_hash = "b3:rcp123"
        \\plan_hash = "b3:plan123"
        \\artifact_hash = "b3:art123"
        \\replay_mode = "declared_host"
        \\runtime = "5.4"
        \\lua_abi = "5.4"
        \\target = "x86_64-linux-gnu"
        \\constellation = "default"
        \\
    ;

    var lf = try lockfile_mod.LockFile.parse(allocator, content);
    defer lf.deinit();

    try std.testing.expectEqual(@as(usize, 1), lf.packages.items.len);
    const pkg = lf.packages.items[0];
    try std.testing.expectEqualStrings("zig-native-demo", pkg.name);
    try std.testing.expectEqual(replay_mod.ReplayMode.declared_host, pkg.replay_mode);
    try std.testing.expectEqualStrings("b3:plan123", pkg.plan_hash);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try lf.serialize(allocator, &aw.writer);
    try aw.writer.flush();

    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "lockfile_version = 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "replay_mode = \"declared_host\"") != null);
}

test "legacy binary registry entries require their exact artifact" {
    const allocator = std.testing.allocator;
    const content =
        \\[[package]]
        \\name = "moonstone/ballad"
        \\version = "0.2.18"
        \\kind = "bin"
        \\recipe_hash = "b3:recipe"
        \\artifact_hash = "b3:artifact"
        \\runtime = "5.4"
        \\lua_abi = "5.1"
        \\target = "native"
        \\source_kind = "bin"
        \\resolver = "store"
        \\
    ;

    var lf = try lockfile_mod.LockFile.parse(allocator, content);
    defer lf.deinit();

    try std.testing.expectEqual(@as(usize, 1), lf.packages.items.len);
    try std.testing.expectEqual(replay_mod.ReplayMode.artifact_only, lf.packages.items[0].replay_mode);
}

test "canonical plan hash stability and tamper detection" {
    const allocator = std.testing.allocator;
    var plan = plan_mod.MaterializationPlan{
        .schema = .moonstone_plan_v1,
        .package_name = try allocator.dupe(u8, "demo"),
        .package_version = try allocator.dupe(u8, "1.0.0"),
        .target = try allocator.dupe(u8, "x86_64-linux-gnu"),
    };
    defer plan.deinit(allocator);

    const hash1 = try plan_mod.computePlanHash(allocator, &plan);
    defer allocator.free(hash1);

    const hash2 = try plan_mod.computePlanHash(allocator, &plan);
    defer allocator.free(hash2);

    try std.testing.expectEqualStrings(hash1, hash2);

    // Tamper: change target
    allocator.free(plan.target);
    plan.target = try allocator.dupe(u8, "aarch64-macos");

    const hash_tampered = try plan_mod.computePlanHash(allocator, &plan);
    defer allocator.free(hash_tampered);

    try std.testing.expect(!std.mem.eql(u8, hash1, hash_tampered));
}

test "host tool version output normalization" {
    const allocator = std.testing.allocator;

    const norm1 = try host_resolver.normalizeVersionOutput(allocator, "zig 0.16.0-dev.123\n");
    defer allocator.free(norm1);
    try std.testing.expectEqualStrings("0.16.0-dev.123", norm1);

    const norm2 = try host_resolver.normalizeVersionOutput(allocator, "cmake version 3.28.1\n");
    defer allocator.free(norm2);
    try std.testing.expectEqualStrings("3.28.1", norm2);
}

test "executor rejects path traversal PlanPathEscape" {
    const allocator = std.testing.allocator;
    var plan = plan_mod.MaterializationPlan{
        .schema = .moonstone_plan_v1,
        .package_name = try allocator.dupe(u8, "bad-path"),
        .package_version = try allocator.dupe(u8, "1.0.0"),
        .target = try allocator.dupe(u8, "native"),
    };
    defer plan.deinit(allocator);

    var tools = try allocator.alloc(plan_mod.ToolRequirement, 1);
    tools[0] = .{ .id = try allocator.dupe(u8, "zig"), .executable = try allocator.dupe(u8, "zig") };
    plan.tools = tools;

    var steps = try allocator.alloc(plan_mod.PlanStep, 1);
    steps[0] = .{
        .name = try allocator.dupe(u8, "bad"),
        .tool_id = try allocator.dupe(u8, "zig"),
        .argv = &.{},
        .cwd = try allocator.dupe(u8, "../escape"),
        .environment = &.{},
    };
    plan.steps = steps;

    try std.testing.expectError(error.InvalidPlanPath, executor_mod.validatePlan(plan));
}
