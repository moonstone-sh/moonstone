const std = @import("std");
const manifest = @import("manifest.zig");

pub const ResolverProvenance = enum {
    rocks,
    moonstone,
    link,
    path,
    url,
    unknown,

    pub fn toString(self: ResolverProvenance) []const u8 {
        return switch (self) {
            .rocks => "rocks",
            .moonstone => "moonstone",
            .link => "link",
            .path => "path",
            .url => "url",
            .unknown => "unknown",
        };
    }

    pub fn fromString(str: []const u8) ResolverProvenance {
        if (std.mem.eql(u8, str, "rocks") or std.mem.eql(u8, str, "luarocks")) return .rocks;
        if (std.mem.eql(u8, str, "moonstone")) return .moonstone;
        if (std.mem.eql(u8, str, "link")) return .link;
        if (std.mem.eql(u8, str, "path")) return .path;
        if (std.mem.eql(u8, str, "url")) return .url;
        return .unknown;
    }
};

pub const PayloadLocatorKind = enum {
    https,
    registry_object,

    pub fn toString(self: PayloadLocatorKind) []const u8 {
        return switch (self) {
            .https => "https",
            .registry_object => "registry_object",
        };
    }

    pub fn fromString(str: []const u8) PayloadLocatorKind {
        if (std.mem.eql(u8, str, "registry_object")) return .registry_object;
        return .https;
    }
};

pub const PayloadLocator = struct {
    kind: PayloadLocatorKind,
    url: []const u8,

    pub fn deinit(self: PayloadLocator, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
    }

    pub fn clone(self: PayloadLocator, allocator: std.mem.Allocator) !PayloadLocator {
        return PayloadLocator{
            .kind = self.kind,
            .url = try allocator.dupe(u8, self.url),
        };
    }
};

pub const LockedPayload = struct {
    kind: []const u8 = "",
    hash: []const u8 = "",
    locators: []PayloadLocator = &.{},

    pub fn deinit(self: LockedPayload, allocator: std.mem.Allocator) void {
        if (self.kind.len > 0) allocator.free(self.kind);
        if (self.hash.len > 0) allocator.free(self.hash);
        for (self.locators) |l| l.deinit(allocator);
        if (self.locators.len > 0) allocator.free(self.locators);
    }

    pub fn clone(self: LockedPayload, allocator: std.mem.Allocator) !LockedPayload {
        var new_locators = try allocator.alloc(PayloadLocator, self.locators.len);
        for (self.locators, 0..) |l, i| {
            new_locators[i] = try l.clone(allocator);
        }
        return LockedPayload{
            .kind = try allocator.dupe(u8, self.kind),
            .hash = try allocator.dupe(u8, self.hash),
            .locators = new_locators,
        };
    }
};

pub const EnvPair = struct {
    key: []const u8,
    value: []const u8,

    pub fn deinit(self: EnvPair, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }

    pub fn clone(self: EnvPair, allocator: std.mem.Allocator) !EnvPair {
        return EnvPair{
            .key = try allocator.dupe(u8, self.key),
            .value = try allocator.dupe(u8, self.value),
        };
    }
};

pub const RecipeV2 = struct {
    kind: []const u8 = "lib",
    name: []const u8 = "",
    version: []const u8 = "",
    source_hash: []const u8 = "",
    materializer: []const u8 = "",
    strategy: []const u8 = "",
    zig_version: []const u8 = "",
    cmake_version: []const u8 = "",
    ldflags: []const []const u8 = &.{},
    runtime_hash: []const u8 = "",
    lua_abi: []const u8 = "",
    target: []const u8 = "",
    sources: []const []const u8 = &.{},
    output_module: []const u8 = "",
    output_path: []const u8 = "",
    collect: []const []const u8 = &.{},
    build_env: []const EnvPair = &.{},

    pub fn deinit(self: RecipeV2, allocator: std.mem.Allocator) void {
        if (self.kind.len > 0) allocator.free(self.kind);
        if (self.name.len > 0) allocator.free(self.name);
        if (self.version.len > 0) allocator.free(self.version);
        if (self.source_hash.len > 0) allocator.free(self.source_hash);
        if (self.materializer.len > 0) allocator.free(self.materializer);
        if (self.strategy.len > 0) allocator.free(self.strategy);
        if (self.zig_version.len > 0) allocator.free(self.zig_version);
        if (self.cmake_version.len > 0) allocator.free(self.cmake_version);
        for (self.ldflags) |flag| allocator.free(flag);
        if (self.ldflags.len > 0) allocator.free(self.ldflags);
        if (self.runtime_hash.len > 0) allocator.free(self.runtime_hash);
        if (self.lua_abi.len > 0) allocator.free(self.lua_abi);
        if (self.target.len > 0) allocator.free(self.target);
        for (self.sources) |src| allocator.free(src);
        if (self.sources.len > 0) allocator.free(self.sources);
        if (self.output_module.len > 0) allocator.free(self.output_module);
        if (self.output_path.len > 0) allocator.free(self.output_path);
        for (self.collect) |c| allocator.free(c);
        if (self.collect.len > 0) allocator.free(self.collect);
        for (self.build_env) |env| env.deinit(allocator);
        if (self.build_env.len > 0) allocator.free(self.build_env);
    }

    pub fn clone(self: RecipeV2, allocator: std.mem.Allocator) !RecipeV2 {
        var new_ldflags = try allocator.alloc([]const u8, self.ldflags.len);
        for (self.ldflags, 0..) |f, i| new_ldflags[i] = try allocator.dupe(u8, f);

        var new_sources = try allocator.alloc([]const u8, self.sources.len);
        for (self.sources, 0..) |s, i| new_sources[i] = try allocator.dupe(u8, s);

        var new_collect = try allocator.alloc([]const u8, self.collect.len);
        for (self.collect, 0..) |c, i| new_collect[i] = try allocator.dupe(u8, c);

        var new_env = try allocator.alloc(EnvPair, self.build_env.len);
        for (self.build_env, 0..) |e, i| new_env[i] = try e.clone(allocator);

        return RecipeV2{
            .kind = try allocator.dupe(u8, self.kind),
            .name = try allocator.dupe(u8, self.name),
            .version = try allocator.dupe(u8, self.version),
            .source_hash = try allocator.dupe(u8, self.source_hash),
            .materializer = try allocator.dupe(u8, self.materializer),
            .strategy = try allocator.dupe(u8, self.strategy),
            .zig_version = try allocator.dupe(u8, self.zig_version),
            .cmake_version = try allocator.dupe(u8, self.cmake_version),
            .ldflags = new_ldflags,
            .runtime_hash = try allocator.dupe(u8, self.runtime_hash),
            .lua_abi = try allocator.dupe(u8, self.lua_abi),
            .target = try allocator.dupe(u8, self.target),
            .sources = new_sources,
            .output_module = try allocator.dupe(u8, self.output_module),
            .output_path = try allocator.dupe(u8, self.output_path),
            .collect = new_collect,
            .build_env = new_env,
        };
    }
};

pub const MaterializerCapability = enum {
    source_replay_supported,
    exact_artifact_required,
    unsupported,
};

pub const RealizationAssurance = enum {
    portable_source,
    declared_host,
    artifact_only,
};

pub const BuildProvenance = struct {
    tool_name: []const u8 = "",
    tool_version: []const u8 = "",
    builder_platform: []const u8 = "",

    pub fn deinit(self: BuildProvenance, allocator: std.mem.Allocator) void {
        if (self.tool_name.len > 0) allocator.free(self.tool_name);
        if (self.tool_version.len > 0) allocator.free(self.tool_version);
        if (self.builder_platform.len > 0) allocator.free(self.builder_platform);
    }

    pub fn clone(self: BuildProvenance, allocator: std.mem.Allocator) !BuildProvenance {
        return BuildProvenance{
            .tool_name = try allocator.dupe(u8, self.tool_name),
            .tool_version = try allocator.dupe(u8, self.tool_version),
            .builder_platform = try allocator.dupe(u8, self.builder_platform),
        };
    }
};

pub const TargetRealization = struct {
    target: []const u8 = "",
    lua_abi: ?[]const u8 = null,
    runtime_artifact_hash: ?[]const u8 = null,
    plan_schema: []const u8 = "moonstone:plan:v1",
    plan_hash: []const u8 = "",
    recipe_hash: []const u8 = "",
    artifact_hash: []const u8 = "",
    assurance: RealizationAssurance = .portable_source,
    provenance: BuildProvenance = .{},
    recipe: RecipeV2 = .{},

    pub fn deinit(self: TargetRealization, allocator: std.mem.Allocator) void {
        if (self.target.len > 0) allocator.free(self.target);
        if (self.lua_abi) |abi| allocator.free(abi);
        if (self.runtime_artifact_hash) |rt| allocator.free(rt);
        if (self.plan_schema.len > 0) allocator.free(self.plan_schema);
        if (self.plan_hash.len > 0) allocator.free(self.plan_hash);
        if (self.recipe_hash.len > 0) allocator.free(self.recipe_hash);
        if (self.artifact_hash.len > 0) allocator.free(self.artifact_hash);
        self.provenance.deinit(allocator);
        self.recipe.deinit(allocator);
    }

    pub fn clone(self: TargetRealization, allocator: std.mem.Allocator) !TargetRealization {
        return TargetRealization{
            .target = try allocator.dupe(u8, self.target),
            .lua_abi = if (self.lua_abi) |abi| try allocator.dupe(u8, abi) else null,
            .runtime_artifact_hash = if (self.runtime_artifact_hash) |rt| try allocator.dupe(u8, rt) else null,
            .plan_schema = try allocator.dupe(u8, self.plan_schema),
            .plan_hash = try allocator.dupe(u8, self.plan_hash),
            .recipe_hash = try allocator.dupe(u8, self.recipe_hash),
            .artifact_hash = try allocator.dupe(u8, self.artifact_hash),
            .assurance = self.assurance,
            .provenance = try self.provenance.clone(allocator),
            .recipe = try self.recipe.clone(allocator),
        };
    }
};

pub const LockedPackage = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    kind: manifest.Kind = .lib,
    provenance: ResolverProvenance = .unknown,
    source: LockedPayload = .{},
    rockspec: ?LockedPayload = null,
    realizations: []TargetRealization = &.{},

    pub fn deinit(self: LockedPackage, allocator: std.mem.Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        if (self.version.len > 0) allocator.free(self.version);
        self.source.deinit(allocator);
        if (self.rockspec) |rs| rs.deinit(allocator);
        for (self.realizations) |r| r.deinit(allocator);
        if (self.realizations.len > 0) allocator.free(self.realizations);
    }

    pub fn clone(self: LockedPackage, allocator: std.mem.Allocator) !LockedPackage {
        var new_reals = try allocator.alloc(TargetRealization, self.realizations.len);
        for (self.realizations, 0..) |r, i| new_reals[i] = try r.clone(allocator);

        return LockedPackage{
            .name = try allocator.dupe(u8, self.name),
            .version = try allocator.dupe(u8, self.version),
            .kind = self.kind,
            .provenance = self.provenance,
            .source = try self.source.clone(allocator),
            .rockspec = if (self.rockspec) |rs| try rs.clone(allocator) else null,
            .realizations = new_reals,
        };
    }
};

pub const MaterializationRequest = struct {
    package_name: []const u8,
    package_version: []const u8,
    kind: manifest.Kind,
    target: []const u8,
    lua_abi: ?[]const u8,
    recipe: RecipeV2,
    source_payload_path: []const u8,
    rockspec_payload_path: ?[]const u8 = null,
};
