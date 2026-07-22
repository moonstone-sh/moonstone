const std = @import("std");
const locked_pkg = @import("locked_package.zig");
const plan_mod = @import("../materialization/plan.zig");

pub const ReplayMode = enum {
    portable_source,
    declared_host,
    artifact_only,

    pub fn toString(self: ReplayMode) []const u8 {
        return switch (self) {
            .portable_source => "portable_source",
            .declared_host => "declared_host",
            .artifact_only => "artifact_only",
        };
    }

    pub fn fromString(str: []const u8) ReplayMode {
        if (std.mem.eql(u8, str, "portable_source")) return .portable_source;
        if (std.mem.eql(u8, str, "declared_host")) return .declared_host;
        return .artifact_only;
    }
};

pub const HostToolKind = enum {
    zig,
    clang,
    cmake,
    ninja,
    make,
    cargo,
    node,
    custom,

    pub fn toString(self: HostToolKind) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(str: []const u8) HostToolKind {
        if (std.mem.eql(u8, str, "zig")) return .zig;
        if (std.mem.eql(u8, str, "clang")) return .clang;
        if (std.mem.eql(u8, str, "cmake")) return .cmake;
        if (std.mem.eql(u8, str, "ninja")) return .ninja;
        if (std.mem.eql(u8, str, "make")) return .make;
        if (std.mem.eql(u8, str, "cargo")) return .cargo;
        if (std.mem.eql(u8, str, "node")) return .node;
        return .custom;
    }
};

pub const HostToolVersionPolicy = enum {
    exact_observed,
    adapter_compatible,

    pub fn toString(self: HostToolVersionPolicy) []const u8 {
        return switch (self) {
            .exact_observed => "exact-observed",
            .adapter_compatible => "adapter-compatible",
        };
    }

    pub fn fromString(str: []const u8) HostToolVersionPolicy {
        if (std.mem.eql(u8, str, "adapter-compatible")) return .adapter_compatible;
        return .exact_observed;
    }
};

pub const HostToolAssurance = enum {
    moonstone_managed,
    exact_external_artifact,
    declared_host_tool,

    pub fn toString(self: HostToolAssurance) []const u8 {
        return @tagName(self);
    }
};

pub const HostToolRequirement = struct {
    id: []const u8,
    kind: HostToolKind,
    executable_names: []const []const u8,
    version_policy: HostToolVersionPolicy = .exact_observed,
    observed_version: ?[]const u8 = null,
    probe_schema: []const u8 = "standard_version",
    assurance: HostToolAssurance = .declared_host_tool,

    pub fn deinit(self: HostToolRequirement, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        for (self.executable_names) |name| allocator.free(name);
        if (self.executable_names.len > 0) allocator.free(self.executable_names);
        if (self.observed_version) |ver| allocator.free(ver);
        if (self.probe_schema.len > 0) allocator.free(self.probe_schema);
    }

    pub fn clone(self: HostToolRequirement, allocator: std.mem.Allocator) !HostToolRequirement {
        var names = try allocator.alloc([]const u8, self.executable_names.len);
        for (self.executable_names, 0..) |n, i| names[i] = try allocator.dupe(u8, n);

        return HostToolRequirement{
            .id = try allocator.dupe(u8, self.id),
            .kind = self.kind,
            .executable_names = names,
            .version_policy = self.version_policy,
            .observed_version = if (self.observed_version) |ver| try allocator.dupe(u8, ver) else null,
            .probe_schema = try allocator.dupe(u8, self.probe_schema),
            .assurance = self.assurance,
        };
    }
};

pub const LockedInputRef = struct {
    id: []const u8,
    kind: []const u8,
    hash: []const u8,
    mount: []const u8,

    pub fn deinit(self: LockedInputRef, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.kind);
        allocator.free(self.hash);
        allocator.free(self.mount);
    }

    pub fn clone(self: LockedInputRef, allocator: std.mem.Allocator) !LockedInputRef {
        return LockedInputRef{
            .id = try allocator.dupe(u8, self.id),
            .kind = try allocator.dupe(u8, self.kind),
            .hash = try allocator.dupe(u8, self.hash),
            .mount = try allocator.dupe(u8, self.mount),
        };
    }
};

pub const ReplayContract = struct {
    schema: []const u8 = "moonstone:replay_contract:v1",
    mode: ReplayMode = .artifact_only,
    materializer_schema: []const u8 = "moonstone:materializer:v1",
    recipe_hash: []const u8 = "",
    plan_hash: []const u8 = "",
    plan: ?plan_mod.MaterializationPlan = null,

    source_inputs: []LockedInputRef = &.{},
    dependency_inputs: []LockedInputRef = &.{},
    runtime_inputs: []LockedInputRef = &.{},
    tool_requirements: []HostToolRequirement = &.{},
    environment: []locked_pkg.EnvPair = &.{},

    pub fn deinit(self: *ReplayContract, allocator: std.mem.Allocator) void {
        if (self.schema.len > 0) allocator.free(self.schema);
        if (self.materializer_schema.len > 0) allocator.free(self.materializer_schema);
        if (self.recipe_hash.len > 0) allocator.free(self.recipe_hash);
        if (self.plan_hash.len > 0) allocator.free(self.plan_hash);

        if (self.plan) |*p| p.deinit(allocator);

        for (self.source_inputs) |inp| inp.deinit(allocator);
        if (self.source_inputs.len > 0) allocator.free(self.source_inputs);

        for (self.dependency_inputs) |inp| inp.deinit(allocator);
        if (self.dependency_inputs.len > 0) allocator.free(self.dependency_inputs);

        for (self.runtime_inputs) |inp| inp.deinit(allocator);
        if (self.runtime_inputs.len > 0) allocator.free(self.runtime_inputs);

        for (self.tool_requirements) |t| t.deinit(allocator);
        if (self.tool_requirements.len > 0) allocator.free(self.tool_requirements);

        for (self.environment) |env| env.deinit(allocator);
        if (self.environment.len > 0) allocator.free(self.environment);
    }

    pub fn clone(self: *const ReplayContract, allocator: std.mem.Allocator) !ReplayContract {
        var src_inps = try allocator.alloc(LockedInputRef, self.source_inputs.len);
        for (self.source_inputs, 0..) |inp, i| src_inps[i] = try inp.clone(allocator);

        var dep_inps = try allocator.alloc(LockedInputRef, self.dependency_inputs.len);
        for (self.dependency_inputs, 0..) |inp, i| dep_inps[i] = try inp.clone(allocator);

        var run_inps = try allocator.alloc(LockedInputRef, self.runtime_inputs.len);
        for (self.runtime_inputs, 0..) |inp, i| run_inps[i] = try inp.clone(allocator);

        var tools = try allocator.alloc(HostToolRequirement, self.tool_requirements.len);
        for (self.tool_requirements, 0..) |t, i| tools[i] = try t.clone(allocator);

        var envs = try allocator.alloc(locked_pkg.EnvPair, self.environment.len);
        for (self.environment, 0..) |e, i| envs[i] = try e.clone(allocator);

        return ReplayContract{
            .schema = try allocator.dupe(u8, self.schema),
            .mode = self.mode,
            .materializer_schema = try allocator.dupe(u8, self.materializer_schema),
            .recipe_hash = try allocator.dupe(u8, self.recipe_hash),
            .plan_hash = try allocator.dupe(u8, self.plan_hash),
            .plan = if (self.plan) |p| try p.clone(allocator) else null,
            .source_inputs = src_inps,
            .dependency_inputs = dep_inps,
            .runtime_inputs = run_inps,
            .tool_requirements = tools,
            .environment = envs,
        };
    }
};
