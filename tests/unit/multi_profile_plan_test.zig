const std = @import("std");
const moonstone = @import("moonstone");
const res_profile = moonstone.domain.resolution_profile;
const plan_mod = moonstone.materialization.plan;
const executor = moonstone.materialization.executor;
const adapter = moonstone.materialization.adapter;

test "Profile identity generation and selection" {
    const allocator = std.testing.allocator;

    const id_mac = try res_profile.generateProfileId(allocator, "aarch64-macos", "lua-5.4", "5.4");
    defer allocator.free(id_mac);
    try std.testing.expectEqualStrings("aarch64-macos+lua-5.4+5.4", id_mac);

    var prof_mac = res_profile.ResolutionProfile{
        .id = try allocator.dupe(u8, id_mac),
        .target = try allocator.dupe(u8, "aarch64-macos"),
        .runtime = try allocator.dupe(u8, "lua-5.4"),
        .lua_abi = try allocator.dupe(u8, "5.4"),
    };
    defer prof_mac.deinit(allocator);

    var prof_linux = res_profile.ResolutionProfile{
        .id = try allocator.dupe(u8, "x86_64-linux+lua-5.4+5.4"),
        .target = try allocator.dupe(u8, "x86_64-linux"),
        .runtime = try allocator.dupe(u8, "lua-5.4"),
        .lua_abi = try allocator.dupe(u8, "5.4"),
    };
    defer prof_linux.deinit(allocator);

    const profiles = [_]res_profile.ResolutionProfile{ prof_mac, prof_linux };

    const selected_mac = res_profile.selectProfile(&profiles, "aarch64-macos", "lua-5.4", "5.4");
    try std.testing.expect(selected_mac != null);
    try std.testing.expectEqualStrings("aarch64-macos", selected_mac.?.target);

    const selected_linux = res_profile.selectProfile(&profiles, "x86_64-linux", "lua-5.4", "5.4");
    try std.testing.expect(selected_linux != null);
    try std.testing.expectEqualStrings("x86_64-linux", selected_linux.?.target);

    const selected_missing = res_profile.selectProfile(&profiles, "riscv64-linux", "lua-5.4", "5.4");
    try std.testing.expect(selected_missing == null);
}

test "Materializer adapter replay assessments" {
    try std.testing.expectEqual(adapter.ReplayAssessment.source_replay_supported, adapter.PureLuaAdapter.assessReplay());
    try std.testing.expectEqual(adapter.ReplayAssessment.exact_artifact_required, adapter.ZigCcAdapter.assessReplay());
    try std.testing.expectEqual(adapter.ReplayAssessment.exact_artifact_required, adapter.CmakeAdapter.assessReplay());
}

test "Plan validation rejects path traversal and undeclared tools" {
    const allocator = std.testing.allocator;

    // Path traversal in output
    var bad_plan = plan_mod.MaterializationPlan{
        .package_name = try allocator.dupe(u8, "bad_pkg"),
        .package_version = try allocator.dupe(u8, "1.0.0"),
        .target = try allocator.dupe(u8, "native"),
        .outputs = try allocator.dupe(plan_mod.OutputRule, &[_]plan_mod.OutputRule{
            .{
                .kind = .copy_file,
                .from = try allocator.dupe(u8, "../etc/passwd"),
                .to = try allocator.dupe(u8, "stolen.txt"),
            },
        }),
    };
    defer bad_plan.deinit(allocator);

    try std.testing.expectError(error.InvalidPlanPath, executor.validatePlan(bad_plan));

    // Undeclared tool in step
    var bad_tool_plan = plan_mod.MaterializationPlan{
        .package_name = try allocator.dupe(u8, "bad_tool_pkg"),
        .package_version = try allocator.dupe(u8, "1.0.0"),
        .target = try allocator.dupe(u8, "native"),
        .steps = try allocator.dupe(plan_mod.PlanStep, &[_]plan_mod.PlanStep{
            .{
                .name = try allocator.dupe(u8, "run_unknown"),
                .tool_id = try allocator.dupe(u8, "nonexistent_tool"),
                .argv = &.{},
            },
        }),
    };
    defer bad_tool_plan.deinit(allocator);

    try std.testing.expectError(error.UndeclaredTool, executor.validatePlan(bad_tool_plan));
}

test "Canonical plan hash computation and sensitivity" {
    const allocator = std.testing.allocator;

    var plan1 = try adapter.PureLuaAdapter.buildPlan(allocator, "inspect", "3.1.3", "aarch64-macos", "inspect");
    defer plan1.deinit(allocator);

    const hash1 = try plan_mod.computePlanHash(allocator, &plan1);
    defer allocator.free(hash1);
    try std.testing.expect(hash1.len > 0);

    // Identical plan produces identical hash
    var plan1_clone = try plan1.clone(allocator);
    defer plan1_clone.deinit(allocator);

    const hash1_clone = try plan_mod.computePlanHash(allocator, &plan1_clone);
    defer allocator.free(hash1_clone);

    try std.testing.expectEqualStrings(hash1, hash1_clone);

    // Differing target produces different plan hash
    var plan2 = try adapter.PureLuaAdapter.buildPlan(allocator, "inspect", "3.1.3", "x86_64-linux", "inspect");
    defer plan2.deinit(allocator);

    const hash2 = try plan_mod.computePlanHash(allocator, &plan2);
    defer allocator.free(hash2);

    try std.testing.expect(!std.mem.eql(u8, hash1, hash2));
}

test "Existing profile immutability check" {
    const allocator = std.testing.allocator;

    var p1 = res_profile.ResolutionProfile{
        .id = try allocator.dupe(u8, "p1"),
        .target = try allocator.dupe(u8, "aarch64-macos"),
        .runtime = try allocator.dupe(u8, "lua-5.4"),
        .packages = try allocator.dupe(res_profile.ProfilePackageRef, &[_]res_profile.ProfilePackageRef{
            .{
                .package_name = try allocator.dupe(u8, "inspect"),
                .package_version = try allocator.dupe(u8, "3.1.3"),
                .realization_hash = try allocator.dupe(u8, "b3:hash1"),
            },
        }),
    };
    defer p1.deinit(allocator);

    const before = [_]res_profile.ResolutionProfile{p1};

    var p1_mutated = try p1.clone(allocator);
    defer p1_mutated.deinit(allocator);
    allocator.free(p1_mutated.packages[0].realization_hash);
    p1_mutated.packages[0].realization_hash = try allocator.dupe(u8, "b3:mutated");

    const after_mutated = [_]res_profile.ResolutionProfile{p1_mutated};

    try std.testing.expectError(error.ExistingProfileMutationDetected, res_profile.verifyProfilesUnchanged(&before, &after_mutated));
}
