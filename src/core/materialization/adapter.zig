const std = @import("std");
const locked_pkg = @import("../domain/locked_package.zig");
const plan_mod = @import("plan.zig");
const MaterializationPlan = plan_mod.MaterializationPlan;

pub const ReplayAssessment = enum {
    source_replay_supported,
    exact_artifact_required,
    unsupported,
};

pub const PureLuaAdapter = struct {
    pub fn assessReplay() ReplayAssessment {
        return .source_replay_supported;
    }

    pub fn buildPlan(
        allocator: std.mem.Allocator,
        package_name: []const u8,
        package_version: []const u8,
        target: []const u8,
        module_path: []const u8,
    ) !MaterializationPlan {
        var outputs = std.ArrayList(plan_mod.OutputRule).empty;
        const mod_dest = try std.fmt.allocPrint(allocator, "share/lua/5.4/{s}.lua", .{package_name});
        defer allocator.free(mod_dest);

        try outputs.append(allocator, .{
            .kind = .lua_module,
            .from = try allocator.dupe(u8, module_path),
            .to = try allocator.dupe(u8, mod_dest),
        });

        return MaterializationPlan{
            .schema = .moonstone_plan_v1,
            .package_name = try allocator.dupe(u8, package_name),
            .package_version = try allocator.dupe(u8, package_version),
            .target = try allocator.dupe(u8, target),
            .inputs = &.{},
            .tools = &.{},
            .environment = &.{},
            .steps = &.{},
            .outputs = try outputs.toOwnedSlice(allocator),
            .network = .denied,
        };
    }
};

pub const ZigCcAdapter = struct {
    pub fn assessReplay() ReplayAssessment {
        return .exact_artifact_required;
    }

    pub fn buildPlan(
        allocator: std.mem.Allocator,
        package_name: []const u8,
        package_version: []const u8,
        target: []const u8,
        sources: []const []const u8,
        output_so_name: []const u8,
    ) !MaterializationPlan {
        var tools = std.ArrayList(plan_mod.ToolRequirement).empty;
        try tools.append(allocator, .{
            .id = try allocator.dupe(u8, "zig"),
            .executable = try allocator.dupe(u8, "zig"),
            .assurance = .declared_host_tool,
        });

        var argv = std.ArrayList([]const u8).empty;
        try argv.append(allocator, try allocator.dupe(u8, "cc"));
        try argv.append(allocator, try allocator.dupe(u8, "-shared"));
        try argv.append(allocator, try allocator.dupe(u8, "-o"));
        try argv.append(allocator, try allocator.dupe(u8, output_so_name));
        for (sources) |src_file| {
            try argv.append(allocator, try allocator.dupe(u8, src_file));
        }

        var steps = std.ArrayList(plan_mod.PlanStep).empty;
        try steps.append(allocator, .{
            .name = try allocator.dupe(u8, "compile_zig_cc"),
            .tool_id = try allocator.dupe(u8, "zig"),
            .argv = try argv.toOwnedSlice(allocator),
            .cwd = try allocator.dupe(u8, "."),
            .environment = &.{},
        });

        var outputs = std.ArrayList(plan_mod.OutputRule).empty;
        const cmod_dest = try std.fmt.allocPrint(allocator, "lib/lua/5.4/{s}", .{output_so_name});
        defer allocator.free(cmod_dest);

        try outputs.append(allocator, .{
            .kind = .lua_cmodule,
            .from = try allocator.dupe(u8, output_so_name),
            .to = try allocator.dupe(u8, cmod_dest),
        });

        return MaterializationPlan{
            .schema = .moonstone_plan_v1,
            .package_name = try allocator.dupe(u8, package_name),
            .package_version = try allocator.dupe(u8, package_version),
            .target = try allocator.dupe(u8, target),
            .inputs = &.{},
            .tools = try tools.toOwnedSlice(allocator),
            .environment = &.{},
            .steps = try steps.toOwnedSlice(allocator),
            .outputs = try outputs.toOwnedSlice(allocator),
            .network = .denied,
        };
    }
};

pub const CmakeAdapter = struct {
    pub fn assessReplay() ReplayAssessment {
        return .exact_artifact_required;
    }

    pub fn buildPlan(
        allocator: std.mem.Allocator,
        package_name: []const u8,
        package_version: []const u8,
        target: []const u8,
    ) !MaterializationPlan {
        var tools = std.ArrayList(plan_mod.ToolRequirement).empty;
        try tools.append(allocator, .{
            .id = try allocator.dupe(u8, "cmake"),
            .executable = try allocator.dupe(u8, "cmake"),
            .assurance = .declared_host_tool,
        });

        var configure_argv = std.ArrayList([]const u8).empty;
        try configure_argv.append(allocator, try allocator.dupe(u8, "-B"));
        try configure_argv.append(allocator, try allocator.dupe(u8, "build"));

        var build_argv = std.ArrayList([]const u8).empty;
        try build_argv.append(allocator, try allocator.dupe(u8, "--build"));
        try build_argv.append(allocator, try allocator.dupe(u8, "build"));

        var steps = std.ArrayList(plan_mod.PlanStep).empty;
        try steps.append(allocator, .{
            .name = try allocator.dupe(u8, "cmake_configure"),
            .tool_id = try allocator.dupe(u8, "cmake"),
            .argv = try configure_argv.toOwnedSlice(allocator),
            .cwd = try allocator.dupe(u8, "."),
            .environment = &.{},
        });
        try steps.append(allocator, .{
            .name = try allocator.dupe(u8, "cmake_build"),
            .tool_id = try allocator.dupe(u8, "cmake"),
            .argv = try build_argv.toOwnedSlice(allocator),
            .cwd = try allocator.dupe(u8, "."),
            .environment = &.{},
        });

        return MaterializationPlan{
            .schema = .moonstone_plan_v1,
            .package_name = try allocator.dupe(u8, package_name),
            .package_version = try allocator.dupe(u8, package_version),
            .target = try allocator.dupe(u8, target),
            .inputs = &.{},
            .tools = try tools.toOwnedSlice(allocator),
            .environment = &.{},
            .steps = try steps.toOwnedSlice(allocator),
            .outputs = &.{},
            .network = .denied,
        };
    }
};
