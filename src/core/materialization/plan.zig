const std = @import("std");
const locked_pkg = @import("../domain/locked_package.zig");

pub const PlanSchema = enum {
    moonstone_plan_v1,

    pub fn toString(self: PlanSchema) []const u8 {
        return switch (self) {
            .moonstone_plan_v1 => "moonstone:plan:v1",
        };
    }
};

pub const ToolAssurance = enum {
    moonstone_managed,
    exact_external_artifact,
    declared_host_tool,
};

pub const ToolRequirement = struct {
    id: []const u8,
    executable: []const u8,
    assurance: ToolAssurance = .declared_host_tool,

    pub fn deinit(self: ToolRequirement, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.executable);
    }

    pub fn clone(self: ToolRequirement, allocator: std.mem.Allocator) !ToolRequirement {
        return ToolRequirement{
            .id = try allocator.dupe(u8, self.id),
            .executable = try allocator.dupe(u8, self.executable),
            .assurance = self.assurance,
        };
    }
};

pub const PlanInput = struct {
    id: []const u8,
    kind: []const u8,
    source_path: []const u8,
    mount_path: []const u8,

    pub fn deinit(self: PlanInput, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.kind);
        allocator.free(self.source_path);
        allocator.free(self.mount_path);
    }

    pub fn clone(self: PlanInput, allocator: std.mem.Allocator) !PlanInput {
        return PlanInput{
            .id = try allocator.dupe(u8, self.id),
            .kind = try allocator.dupe(u8, self.kind),
            .source_path = try allocator.dupe(u8, self.source_path),
            .mount_path = try allocator.dupe(u8, self.mount_path),
        };
    }
};

pub const PlanStep = struct {
    name: []const u8,
    tool_id: []const u8,
    argv: []const []const u8,
    cwd: []const u8 = ".",
    environment: []const locked_pkg.EnvPair = &.{},

    pub fn deinit(self: PlanStep, allocator: std.mem.Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        if (self.tool_id.len > 0) allocator.free(self.tool_id);
        for (self.argv) |arg| allocator.free(arg);
        if (self.argv.len > 0) allocator.free(self.argv);
        if (self.cwd.len > 0 and !std.mem.eql(u8, self.cwd, ".")) allocator.free(self.cwd);
        for (self.environment) |env| env.deinit(allocator);
        if (self.environment.len > 0) allocator.free(self.environment);
    }

    pub fn clone(self: PlanStep, allocator: std.mem.Allocator) !PlanStep {
        var new_argv = try allocator.alloc([]const u8, self.argv.len);
        for (self.argv, 0..) |arg, i| new_argv[i] = try allocator.dupe(u8, arg);

        var new_env = try allocator.alloc(locked_pkg.EnvPair, self.environment.len);
        for (self.environment, 0..) |e, i| new_env[i] = try e.clone(allocator);

        return PlanStep{
            .name = try allocator.dupe(u8, self.name),
            .tool_id = try allocator.dupe(u8, self.tool_id),
            .argv = new_argv,
            .cwd = try allocator.dupe(u8, self.cwd),
            .environment = new_env,
        };
    }
};

pub const OutputRuleKind = enum {
    copy_file,
    copy_tree,
    lua_module,
    lua_cmodule,
    executable,
};

pub const OutputRule = struct {
    kind: OutputRuleKind,
    from: []const u8,
    to: []const u8,
    executable: bool = false,

    pub fn deinit(self: OutputRule, allocator: std.mem.Allocator) void {
        allocator.free(self.from);
        allocator.free(self.to);
    }

    pub fn clone(self: OutputRule, allocator: std.mem.Allocator) !OutputRule {
        return OutputRule{
            .kind = self.kind,
            .from = try allocator.dupe(u8, self.from),
            .to = try allocator.dupe(u8, self.to),
            .executable = self.executable,
        };
    }
};

pub const NetworkPolicy = enum {
    denied,
    allowed,
};

pub const MaterializationPlan = struct {
    schema: PlanSchema = .moonstone_plan_v1,
    package_name: []const u8 = "",
    package_version: []const u8 = "",
    target: []const u8 = "native",

    inputs: []PlanInput = &.{},
    tools: []ToolRequirement = &.{},
    environment: []locked_pkg.EnvPair = &.{},
    steps: []PlanStep = &.{},
    outputs: []OutputRule = &.{},
    network: NetworkPolicy = .denied,

    pub fn deinit(self: MaterializationPlan, allocator: std.mem.Allocator) void {
        if (self.package_name.len > 0) allocator.free(self.package_name);
        if (self.package_version.len > 0) allocator.free(self.package_version);
        if (self.target.len > 0) allocator.free(self.target);

        for (self.inputs) |in_val| in_val.deinit(allocator);
        if (self.inputs.len > 0) allocator.free(self.inputs);

        for (self.tools) |t| t.deinit(allocator);
        if (self.tools.len > 0) allocator.free(self.tools);

        for (self.environment) |env| env.deinit(allocator);
        if (self.environment.len > 0) allocator.free(self.environment);

        for (self.steps) |s| s.deinit(allocator);
        if (self.steps.len > 0) allocator.free(self.steps);

        for (self.outputs) |o| o.deinit(allocator);
        if (self.outputs.len > 0) allocator.free(self.outputs);
    }

    pub fn clone(self: MaterializationPlan, allocator: std.mem.Allocator) !MaterializationPlan {
        var new_inputs = try allocator.alloc(PlanInput, self.inputs.len);
        for (self.inputs, 0..) |inp, i| new_inputs[i] = try inp.clone(allocator);

        var new_tools = try allocator.alloc(ToolRequirement, self.tools.len);
        for (self.tools, 0..) |t, i| new_tools[i] = try t.clone(allocator);

        var new_env = try allocator.alloc(locked_pkg.EnvPair, self.environment.len);
        for (self.environment, 0..) |e, i| new_env[i] = try e.clone(allocator);

        var new_steps = try allocator.alloc(PlanStep, self.steps.len);
        for (self.steps, 0..) |s, i| new_steps[i] = try s.clone(allocator);

        var new_outputs = try allocator.alloc(OutputRule, self.outputs.len);
        for (self.outputs, 0..) |o, i| new_outputs[i] = try o.clone(allocator);

        return MaterializationPlan{
            .schema = self.schema,
            .package_name = try allocator.dupe(u8, self.package_name),
            .package_version = try allocator.dupe(u8, self.package_version),
            .target = try allocator.dupe(u8, self.target),
            .inputs = new_inputs,
            .tools = new_tools,
            .environment = new_env,
            .steps = new_steps,
            .outputs = new_outputs,
            .network = self.network,
        };
    }
};

pub fn computePlanHash(allocator: std.mem.Allocator, plan: *const MaterializationPlan) ![]const u8 {
    const hash_mod = @import("../identity/hash.zig");
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    const header = try std.fmt.allocPrint(allocator, "moonstone:plan:v1\npackage_name={s}\npackage_version={s}\ntarget={s}\nnetwork={s}\n", .{
        plan.package_name,
        plan.package_version,
        plan.target,
        @tagName(plan.network),
    });
    defer allocator.free(header);
    try buf.appendSlice(allocator, header);

    for (plan.inputs) |inp| {
        const line = try std.fmt.allocPrint(allocator, "input={s}:{s}:{s}:{s}\n", .{ inp.id, inp.kind, inp.source_path, inp.mount_path });
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }
    for (plan.tools) |t| {
        const line = try std.fmt.allocPrint(allocator, "tool={s}:{s}:{s}\n", .{ t.id, t.executable, @tagName(t.assurance) });
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }
    for (plan.environment) |env| {
        const line = try std.fmt.allocPrint(allocator, "env={s}={s}\n", .{ env.key, env.value });
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }
    for (plan.steps) |step| {
        const line = try std.fmt.allocPrint(allocator, "step={s}:{s}:{s}\n", .{ step.name, step.tool_id, step.cwd });
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
        for (step.argv) |arg| {
            const arg_line = try std.fmt.allocPrint(allocator, "  arg={s}\n", .{arg});
            defer allocator.free(arg_line);
            try buf.appendSlice(allocator, arg_line);
        }
    }
    for (plan.outputs) |out_rule| {
        const line = try std.fmt.allocPrint(allocator, "output={s}:{s}:{s}\n", .{ @tagName(out_rule.kind), out_rule.from, out_rule.to });
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }

    const hex = try hash_mod.blake3_hex(allocator, buf.items);
    defer allocator.free(hex);
    return try std.fmt.allocPrint(allocator, "b3:{s}", .{hex});
}
