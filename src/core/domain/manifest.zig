const std = @import("std");
pub const toml = @import("toml");
const script_mod = @import("script.zig");

pub const Kind = enum {
    script,
    lib,
    bin,
    runtime,

    pub fn from_string(s: []const u8) !Kind {
        if (std.mem.eql(u8, s, "script")) return .script;
        if (std.mem.eql(u8, s, "lib") or std.mem.eql(u8, s, "c_module") or std.mem.eql(u8, s, "lua_module")) return .lib;
        if (std.mem.eql(u8, s, "bin")) return .bin;
        if (std.mem.eql(u8, s, "runtime")) return .runtime;
        return error.InvalidKind;
    }

    pub fn as_string(self: Kind) []const u8 {
        return @tagName(self);
    }
};

fn packageKindFromString(s: []const u8) !Kind {
    if (std.mem.eql(u8, s, "script")) return .script;
    if (std.mem.eql(u8, s, "lib")) return .lib;
    if (std.mem.eql(u8, s, "bin")) return .bin;
    if (std.mem.eql(u8, s, "runtime")) return .runtime;
    return error.InvalidPackageKind;
}

pub const dependency_role = @import("dependency_role.zig");
pub const DependencyRole = dependency_role.DependencyRole;

pub fn parseDependencyRole(role_str: []const u8) !DependencyRole {
    if (std.mem.eql(u8, role_str, "dependency")) {
        // TODO: remove legacy support as we consolidize towards v1.
        return error.LegacyDependencyRole;
    }
    return DependencyRole.fromString(role_str) orelse error.InvalidDependencyRole;
}

pub const RuntimeProvision = struct {
    name: []const u8,
    version: []const u8,
    abi: []const u8,
    compatible_abis: []const []const u8 = &.{},

    pub fn deinit(self: RuntimeProvision, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.abi);
        for (self.compatible_abis) |a| allocator.free(a);
        allocator.free(self.compatible_abis);
    }

    pub fn clone(self: RuntimeProvision, allocator: std.mem.Allocator) !RuntimeProvision {
        var abis = std.ArrayList([]const u8).empty;
        for (self.compatible_abis) |a| try abis.append(allocator, try allocator.dupe(u8, a));
        return RuntimeProvision{
            .name = try allocator.dupe(u8, self.name),
            .version = try allocator.dupe(u8, self.version),
            .abi = try allocator.dupe(u8, self.abi),
            .compatible_abis = try abis.toOwnedSlice(allocator),
        };
    }
};

pub const NativeLibraryLinkage = enum {
    unknown,
    shared,
    static,
};

pub const FeatureProvision = struct {
    name: []const u8,
    path: []const u8,
    entry_point: ?[]const u8 = null,
    module: ?[]const u8 = null,
    linkage: NativeLibraryLinkage = .unknown,

    pub fn deinit(self: FeatureProvision, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        if (self.entry_point) |ep| allocator.free(ep);
        if (self.module) |m| allocator.free(m);
    }

    pub fn clone(self: FeatureProvision, allocator: std.mem.Allocator) !FeatureProvision {
        return FeatureProvision{
            .name = try allocator.dupe(u8, self.name),
            .path = try allocator.dupe(u8, self.path),
            .entry_point = if (self.entry_point) |ep| try allocator.dupe(u8, ep) else null,
            .module = if (self.module) |m| try allocator.dupe(u8, m) else null,
            .linkage = self.linkage,
        };
    }
};

pub const RegistryRoot = struct {
    registry: struct {
        id: []const u8,
        name: []const u8,
        protocol: []const u8,
        revision: u32,
        generated_at: []const u8,
        min_client: []const u8,
    },
    index: struct {
        format: []const u8,
        url: []const u8,
        hash: []const u8,
        bytes: ?u64 = null,
        revision: ?u32 = null,
        compact: ?struct {
            format: []const u8,
            url: []const u8,
            compressed_hash: []const u8,
            compressed_bytes: ?u64 = null,
            content_hash: []const u8,
            content_bytes: ?u64 = null,
            revision: ?u32 = null,
        } = null,
    },
    blobs: struct {
        algorithm: []const u8,
        layout: []const u8,
    },
    capabilities: struct {
        runtimes: bool = true,
        artifacts: bool = true,
        source_packages: bool = true,
        rocks_bridge: bool = false,
        private: bool = false,
    },

    pub fn parse(allocator: std.mem.Allocator, content: []const u8) !RegistryRoot {
        var parser = toml.Parser(RegistryRoot).init(allocator);
        defer parser.deinit();
        const res = try parser.parseString(content);
        return res.value;
    }

    pub fn deinit(self: *RegistryRoot, allocator: std.mem.Allocator) void {
        allocator.free(self.registry.id);
        allocator.free(self.registry.name);
        allocator.free(self.registry.protocol);
        allocator.free(self.registry.generated_at);
        allocator.free(self.registry.min_client);
        allocator.free(self.index.format);
        allocator.free(self.index.url);
        allocator.free(self.index.hash);
        if (self.index.compact) |c| {
            allocator.free(c.format);
            allocator.free(c.url);
            allocator.free(c.compressed_hash);
            allocator.free(c.content_hash);
        }
        allocator.free(self.blobs.algorithm);
        allocator.free(self.blobs.layout);
    }
};

pub const RemotePackageStoreIndex = struct {
    package: []const struct {
        name: []const u8,
        version: []const u8,
        kind: Kind,
        descriptor: []const u8,
        descriptor_hash: []const u8,
        targets: []const []const u8 = &.{},
        runtimes: []const []const u8 = &.{},
    },

    pub fn parse(allocator: std.mem.Allocator, content: []const u8) !RemotePackageStoreIndex {
        var parser = toml.Parser(RemotePackageStoreIndex).init(allocator);
        defer parser.deinit();
        const res = try parser.parseString(content);
        return res.value;
    }

    pub fn deinit(self: RemotePackageStoreIndex, allocator: std.mem.Allocator) void {
        for (self.package) |pkg| {
            allocator.free(pkg.name);
            allocator.free(pkg.version);
            allocator.free(pkg.descriptor);
            allocator.free(pkg.descriptor_hash);
            for (pkg.targets) |t| allocator.free(t);
            allocator.free(pkg.targets);
            for (pkg.runtimes) |r| allocator.free(r);
            allocator.free(pkg.runtimes);
        }
        allocator.free(self.package);
    }
};

pub const EnvPair = struct {
    key: []const u8,
    value: []const u8,
};

pub const CommandStep = struct {
    command: []const u8,
    args: []const []const u8 = &.{},

    pub fn clone(self: CommandStep, allocator: std.mem.Allocator) !CommandStep {
        var args = std.ArrayList([]const u8).empty;
        for (self.args) |a| try args.append(allocator, try allocator.dupe(u8, a));
        return CommandStep{
            .command = try allocator.dupe(u8, self.command),
            .args = try args.toOwnedSlice(allocator),
        };
    }
};

pub const CollectConfig = struct {
    lua_cmodules: []const FeatureProvision = &.{},
    lua_modules: []const FeatureProvision = &.{},
    bins: []const FeatureProvision = &.{},
    headers: []const FeatureProvision = &.{},
    native_lib: []const FeatureProvision = &.{},
    assets: []const FeatureProvision = &.{},

    pub fn clone(self: CollectConfig, allocator: std.mem.Allocator) !CollectConfig {
        var res = CollectConfig{};
        res.lua_cmodules = try self.cloneList(FeatureProvision, self.lua_cmodules, allocator);
        res.lua_modules = try self.cloneList(FeatureProvision, self.lua_modules, allocator);
        res.bins = try self.cloneList(FeatureProvision, self.bins, allocator);
        res.headers = try self.cloneList(FeatureProvision, self.headers, allocator);
        res.native_lib = try self.cloneList(FeatureProvision, self.native_lib, allocator);
        res.assets = try self.cloneList(FeatureProvision, self.assets, allocator);
        return res;
    }

    fn cloneList(self: CollectConfig, comptime T: type, list: []const T, allocator: std.mem.Allocator) ![]const T {
        _ = self;
        var res = std.ArrayList(T).empty;
        for (list) |item| try res.append(allocator, try item.clone(allocator));
        return try res.toOwnedSlice(allocator);
    }
};

pub const MaterializeInput = struct {
    sources: []const []const u8 = &.{},
};

pub const MaterializeOutput = struct {
    module: []const u8,
    path: []const u8,
};

pub const MaterializeConfig = struct {
    kind: []const u8,
    strategy: ?[]const u8 = null,
    input: ?MaterializeInput = null,
    output: ?MaterializeOutput = null,
    command: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    steps: []const CommandStep = &.{},
    env: []const EnvPair = &.{},
    collect: CollectConfig = .{},
    ldflags: []const []const u8 = &.{},

    pub fn parse(allocator: std.mem.Allocator, table: toml.Table) !MaterializeConfig {
        var self = MaterializeConfig{
            .kind = try allocator.dupe(u8, table.get("type").?.string),
            .strategy = if (table.get("strategy")) |s| try allocator.dupe(u8, s.string) else null,
        };

        if (table.get("command")) |c| self.command = try allocator.dupe(u8, c.string);
        if (table.get("args")) |a| {
            var alist = std.ArrayList([]const u8).empty;
            for (a.array.items) |v| try alist.append(allocator, try allocator.dupe(u8, v.string));
            self.args = try alist.toOwnedSlice(allocator);
        }

        if (table.get("steps")) |s_arr| {
            var slist = std.ArrayList(CommandStep).empty;
            for (s_arr.array.items) |s_val| {
                var step = CommandStep{ .command = try allocator.dupe(u8, s_val.table.get("command").?.string) };
                if (s_val.table.get("args")) |sa_val| {
                    var sa_list = std.ArrayList([]const u8).empty;
                    for (sa_val.array.items) |sa| try sa_list.append(allocator, try allocator.dupe(u8, sa.string));
                    step.args = try sa_list.toOwnedSlice(allocator);
                }
                try slist.append(allocator, step);
            }
            self.steps = try slist.toOwnedSlice(allocator);
        }

        if (table.get("env")) |e_table| {
            var elist = std.ArrayList(EnvPair).empty;
            var it = e_table.table.iterator();
            while (it.next()) |entry| {
                try elist.append(allocator, .{
                    .key = try allocator.dupe(u8, entry.key_ptr.*),
                    .value = try allocator.dupe(u8, entry.value_ptr.string),
                });
            }
            self.env = try elist.toOwnedSlice(allocator);
        }

        if (table.get("input")) |i_val| {
            if (i_val.table.get("sources")) |srcs| {
                var slist = std.ArrayList([]const u8).empty;
                for (srcs.array.items) |s| try slist.append(allocator, try allocator.dupe(u8, s.string));
                self.input = .{ .sources = try slist.toOwnedSlice(allocator) };
            }
        }

        if (table.get("output")) |o_val| {
            self.output = .{
                .module = try allocator.dupe(u8, o_val.table.get("module").?.string),
                .path = try allocator.dupe(u8, o_val.table.get("path").?.string),
            };
        }

        if (table.get("collect")) |c_val| {
            const ct = c_val.table;
            if (ct.get("lua_cmodules")) |v| {
                var flist = std.ArrayList(FeatureProvision).empty;
                for (v.array.items) |fv| try flist.append(allocator, .{
                    .name = try allocator.dupe(u8, fv.table.get("name").?.string),
                    .path = try allocator.dupe(u8, fv.table.get("path").?.string),
                });
                self.collect.lua_cmodules = try flist.toOwnedSlice(allocator);
            }
            if (ct.get("lua_modules")) |v| {
                var flist = std.ArrayList(FeatureProvision).empty;
                for (v.array.items) |fv| try flist.append(allocator, .{
                    .name = try allocator.dupe(u8, fv.table.get("name").?.string),
                    .path = try allocator.dupe(u8, fv.table.get("path").?.string),
                });
                self.collect.lua_modules = try flist.toOwnedSlice(allocator);
            }
            if (ct.get("bins")) |v| {
                var flist = std.ArrayList(FeatureProvision).empty;
                for (v.array.items) |fv| try flist.append(allocator, .{
                    .name = try allocator.dupe(u8, fv.table.get("name").?.string),
                    .path = try allocator.dupe(u8, fv.table.get("path").?.string),
                });
                self.collect.bins = try flist.toOwnedSlice(allocator);
            }
            if (ct.get("headers")) |v| {
                var flist = std.ArrayList(FeatureProvision).empty;
                for (v.array.items) |fv| try flist.append(allocator, .{
                    .name = try allocator.dupe(u8, fv.table.get("name").?.string),
                    .path = try allocator.dupe(u8, fv.table.get("path").?.string),
                });
                self.collect.headers = try flist.toOwnedSlice(allocator);
            }
            if (ct.get("native_lib")) |v| {
                var flist = std.ArrayList(FeatureProvision).empty;
                for (v.array.items) |fv| try flist.append(allocator, .{
                    .name = try allocator.dupe(u8, fv.table.get("name").?.string),
                    .path = try allocator.dupe(u8, fv.table.get("path").?.string),
                });
                self.collect.native_lib = try flist.toOwnedSlice(allocator);
            }
        }

        return self;
    }

    pub fn clone(self: MaterializeConfig, allocator: std.mem.Allocator) !MaterializeConfig {
        var res = MaterializeConfig{
            .kind = try allocator.dupe(u8, self.kind),
            .strategy = if (self.strategy) |s| try allocator.dupe(u8, s) else null,
            .input = null,
            .output = null,
            .command = if (self.command) |c| try allocator.dupe(u8, c) else null,
            .args = &.{},
            .steps = &.{},
            .env = &.{},
            .collect = try self.collect.clone(allocator),
            .ldflags = &.{},
        };

        if (self.input) |i| {
            var srcs = std.ArrayList([]const u8).empty;
            for (i.sources) |s| try srcs.append(allocator, try allocator.dupe(u8, s));
            res.input = .{ .sources = try srcs.toOwnedSlice(allocator) };
        }
        if (self.output) |o| {
            res.output = .{
                .module = try allocator.dupe(u8, o.module),
                .path = try allocator.dupe(u8, o.path),
            };
        }
        if (self.args.len > 0) {
            var alist = std.ArrayList([]const u8).empty;
            for (self.args) |a| try alist.append(allocator, try allocator.dupe(u8, a));
            res.args = try alist.toOwnedSlice(allocator);
        }
        if (self.steps.len > 0) {
            var slist = std.ArrayList(CommandStep).empty;
            for (self.steps) |s| try slist.append(allocator, try s.clone(allocator));
            res.steps = try slist.toOwnedSlice(allocator);
        }
        if (self.env.len > 0) {
            var elist = std.ArrayList(EnvPair).empty;
            for (self.env) |e| try elist.append(allocator, .{ .key = try allocator.dupe(u8, e.key), .value = try allocator.dupe(u8, e.value) });
            res.env = try elist.toOwnedSlice(allocator);
        }
        if (self.ldflags.len > 0) {
            var ldlist = std.ArrayList([]const u8).empty;
            for (self.ldflags) |c| try ldlist.append(allocator, try allocator.dupe(u8, c));
            res.ldflags = try ldlist.toOwnedSlice(allocator);
        }
        return res;
    }

    pub fn deinit(self: *MaterializeConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        if (self.strategy) |s| allocator.free(s);
        if (self.input) |i| {
            for (i.sources) |s| allocator.free(s);
            allocator.free(i.sources);
        }
        if (self.output) |o| {
            allocator.free(o.module);
            allocator.free(o.path);
        }
        if (self.command) |c| allocator.free(c);
        for (self.args) |a| allocator.free(a);
        allocator.free(self.args);

        for (self.steps) |s| {
            allocator.free(s.command);
            for (s.args) |a| allocator.free(a);
            allocator.free(s.args);
        }
        allocator.free(self.steps);

        for (self.env) |e| {
            allocator.free(e.key);
            allocator.free(e.value);
        }
        allocator.free(self.env);

        for (self.collect.lua_modules) |p| p.deinit(allocator);
        allocator.free(self.collect.lua_modules);
        for (self.collect.lua_cmodules) |p| p.deinit(allocator);
        allocator.free(self.collect.lua_cmodules);
        for (self.collect.bins) |p| p.deinit(allocator);
        allocator.free(self.collect.bins);
        for (self.collect.headers) |p| p.deinit(allocator);
        allocator.free(self.collect.headers);
        for (self.collect.native_lib) |p| p.deinit(allocator);
        allocator.free(self.collect.native_lib);

        for (self.ldflags) |ca| allocator.free(ca);
        allocator.free(self.ldflags);
    }
};

pub const Provides = struct {
    runtime: []const RuntimeProvision = &.{},
    bin: []const FeatureProvision = &.{},
    bin_lua: []const FeatureProvision = &.{},
    headers: []const FeatureProvision = &.{},
    native_lib: []const FeatureProvision = &.{},
    lua_module: []const FeatureProvision = &.{},
    lua_cmodule: []const FeatureProvision = &.{},
    script: []const FeatureProvision = &.{},
    asset: []const FeatureProvision = &.{},
    ballad_plugin: []const FeatureProvision = &.{},

    pub fn clone(self: Provides, allocator: std.mem.Allocator) !Provides {
        var res = Provides{};
        res.runtime = try self.cloneList(RuntimeProvision, self.runtime, allocator);
        res.bin = try self.cloneList(FeatureProvision, self.bin, allocator);
        res.bin_lua = try self.cloneList(FeatureProvision, self.bin_lua, allocator);
        res.headers = try self.cloneList(FeatureProvision, self.headers, allocator);
        res.native_lib = try self.cloneList(FeatureProvision, self.native_lib, allocator);
        res.lua_module = try self.cloneList(FeatureProvision, self.lua_module, allocator);
        res.lua_cmodule = try self.cloneList(FeatureProvision, self.lua_cmodule, allocator);
        res.script = try self.cloneList(FeatureProvision, self.script, allocator);
        res.asset = try self.cloneList(FeatureProvision, self.asset, allocator);
        res.ballad_plugin = try self.cloneList(FeatureProvision, self.ballad_plugin, allocator);
        return res;
    }

    pub fn deinit(self: *Provides, allocator: std.mem.Allocator) void {
        for (self.runtime) |rt| {
            var mut_rt = rt;
            mut_rt.deinit(allocator);
        }
        allocator.free(self.runtime);
        for (self.bin) |p| p.deinit(allocator);
        allocator.free(self.bin);
        for (self.bin_lua) |p| p.deinit(allocator);
        allocator.free(self.bin_lua);
        for (self.headers) |p| p.deinit(allocator);
        allocator.free(self.headers);
        for (self.native_lib) |p| p.deinit(allocator);
        allocator.free(self.native_lib);
        for (self.lua_module) |p| p.deinit(allocator);
        allocator.free(self.lua_module);
        for (self.lua_cmodule) |p| p.deinit(allocator);
        allocator.free(self.lua_cmodule);
        for (self.script) |p| p.deinit(allocator);
        allocator.free(self.script);
        for (self.asset) |p| p.deinit(allocator);
        allocator.free(self.asset);
        for (self.ballad_plugin) |p| p.deinit(allocator);
        allocator.free(self.ballad_plugin);
    }

    fn cloneList(self: Provides, comptime T: type, list: []const T, allocator: std.mem.Allocator) ![]const T {
        _ = self;
        var res = std.ArrayList(T).empty;
        for (list) |item| try res.append(allocator, try item.clone(allocator));
        return try res.toOwnedSlice(allocator);
    }
};

pub const RemoteArtifact = struct {
    id: []const u8 = "",
    kind: []const u8 = "",
    target: []const u8 = "",
    lua_api: []const u8 = "",
    lua_abi: []const u8 = "",
    runtime: []const u8 = "",
    runtime_artifact_hash: []const u8 = "",
    native_compat_required: bool = false,
    url: []const u8,
    hash: []const u8,
    source_hash: []const u8 = "",
    source_url: []const u8 = "",
    source_kind: []const u8 = "",
    source_format: []const u8 = "",
    format: []const u8,
    bytes: ?u64 = null,
    recipe_hash: []const u8 = "",
    layout: struct {
        strip_components: u32 = 0,
    } = .{},
    materialize: ?MaterializeConfig = null,
    provides: Provides = .{},

    pub fn clone(self: RemoteArtifact, allocator: std.mem.Allocator) !RemoteArtifact {
        var res: RemoteArtifact = undefined;
        res.id = try allocator.dupe(u8, self.id);
        res.kind = try allocator.dupe(u8, self.kind);
        res.target = try allocator.dupe(u8, self.target);
        res.lua_api = try allocator.dupe(u8, self.lua_api);
        res.lua_abi = try allocator.dupe(u8, self.lua_abi);
        res.runtime = try allocator.dupe(u8, self.runtime);
        res.runtime_artifact_hash = try allocator.dupe(u8, self.runtime_artifact_hash);
        res.native_compat_required = self.native_compat_required;
        res.url = try allocator.dupe(u8, self.url);
        res.hash = try allocator.dupe(u8, self.hash);
        res.source_hash = try allocator.dupe(u8, self.source_hash);
        res.source_url = try allocator.dupe(u8, self.source_url);
        res.source_kind = try allocator.dupe(u8, self.source_kind);
        res.source_format = try allocator.dupe(u8, self.source_format);
        res.format = try allocator.dupe(u8, self.format);
        res.bytes = self.bytes;
        res.recipe_hash = try allocator.dupe(u8, self.recipe_hash);
        res.layout = self.layout;
        res.materialize = if (self.materialize) |m| try m.clone(allocator) else null;
        res.provides = try self.provides.clone(allocator);

        return res;
    }

    pub fn deinit(self: *RemoteArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.kind);
        allocator.free(self.target);
        allocator.free(self.lua_api);
        allocator.free(self.lua_abi);
        allocator.free(self.runtime);
        allocator.free(self.runtime_artifact_hash);
        allocator.free(self.url);
        allocator.free(self.hash);
        allocator.free(self.source_hash);
        allocator.free(self.source_url);
        allocator.free(self.source_kind);
        allocator.free(self.source_format);
        allocator.free(self.format);
        allocator.free(self.recipe_hash);
        if (self.materialize) |*m| m.deinit(allocator);
        self.provides.deinit(allocator);
    }
};

fn parseArtifactRuntimeValue(allocator: std.mem.Allocator, value: toml.Value) ![]const u8 {
    return switch (value) {
        .string => |runtime| blk: {
            if (std.mem.startsWith(u8, runtime, "table:")) break :blk try allocator.dupe(u8, "");
            break :blk try allocator.dupe(u8, runtime);
        },
        .table => |runtime_table| blk: {
            const name_value = runtime_table.get("name") orelse break :blk try allocator.dupe(u8, "");
            if (name_value != .string) break :blk try allocator.dupe(u8, "");
            const version_value = runtime_table.get("version") orelse break :blk try allocator.dupe(u8, name_value.string);
            if (version_value != .string or version_value.string.len == 0) break :blk try allocator.dupe(u8, name_value.string);
            break :blk try std.fmt.allocPrint(allocator, "{s}@{s}", .{ name_value.string, version_value.string });
        },
        else => try allocator.dupe(u8, ""),
    };
}

pub const RemotePackageDescriptor = struct {
    package: struct {
        name: []const u8,
        version: []const u8,
        kind: Kind,
        description: ?[]const u8 = null,
        readme: ?[]const u8 = null,
    },
    runtime_bundled: ?struct {
        name: []const u8,
        version: []const u8,
        target: []const u8,
        artifact_hash: []const u8,
    } = null,
    compat: struct {
        runtimes: []const []const u8 = &.{},
    },
    dependencies: []const StoreDependency = &.{},
    artifact: []const RemoteArtifact = &.{},
    source: ?struct {
        kind: []const u8,
        format: []const u8,
        url: ?[]const u8 = null,
        hash: []const u8,
    } = null,

    pub fn clone(self: RemotePackageDescriptor, allocator: std.mem.Allocator) !RemotePackageDescriptor {
        var res: RemotePackageDescriptor = undefined;
        res.package.name = try allocator.dupe(u8, self.package.name);
        res.package.version = try allocator.dupe(u8, self.package.version);
        res.package.kind = self.package.kind;
        res.package.description = if (self.package.description) |d| try allocator.dupe(u8, d) else null;
        res.package.readme = if (self.package.readme) |r| try allocator.dupe(u8, r) else null;

        if (self.runtime_bundled) |rb| {
            res.runtime_bundled = .{
                .name = try allocator.dupe(u8, rb.name),
                .version = try allocator.dupe(u8, rb.version),
                .target = try allocator.dupe(u8, rb.target),
                .artifact_hash = try allocator.dupe(u8, rb.artifact_hash),
            };
        } else res.runtime_bundled = null;

        var rts = std.ArrayList([]const u8).empty;
        for (self.compat.runtimes) |rt| try rts.append(allocator, try allocator.dupe(u8, rt));
        res.compat.runtimes = try rts.toOwnedSlice(allocator);

        var deps = std.ArrayList(StoreDependency).empty;
        for (self.dependencies) |dep| {
            try deps.append(allocator, .{
                .name = try allocator.dupe(u8, dep.name),
                .constraint = try allocator.dupe(u8, dep.constraint),
                .resolver = if (dep.resolver) |r| try allocator.dupe(u8, r) else null,
                .role = dep.role,
                .optional = dep.optional,
            });
        }
        res.dependencies = try deps.toOwnedSlice(allocator);

        var arts = std.ArrayList(RemoteArtifact).empty;
        for (self.artifact) |art| try arts.append(allocator, try art.clone(allocator));
        res.artifact = try arts.toOwnedSlice(allocator);

        if (self.source) |s| {
            res.source = .{
                .kind = try allocator.dupe(u8, s.kind),
                .format = try allocator.dupe(u8, s.format),
                .url = if (s.url) |u| try allocator.dupe(u8, u) else null,
                .hash = try allocator.dupe(u8, s.hash),
            };
        } else res.source = null;

        return res;
    }

    pub fn parse(allocator: std.mem.Allocator, content: []const u8) !RemotePackageDescriptor {
        var parser = toml.Parser(toml.Table).init(allocator);
        defer parser.deinit();
        const res = try parser.parseString(content);
        const table = res.value;

        if (table.get("artifact") != null or table.get("compat") != null or table.get("source") != null) return error.LegacyRegistryDescriptor;

        var self = RemotePackageDescriptor{
            .package = .{
                .name = "",
                .version = "",
                .kind = .lib,
            },
            .compat = .{ .runtimes = &.{} },
            .dependencies = &.{},
            .artifact = &.{},
            .source = null,
        };

        const package_val = table.get("package") orelse return error.MissingPackageSection;
        if (package_val != .table) return error.InvalidPackageSection;
        const p_val = package_val.table;
        self.package = .{
            .name = try allocator.dupe(u8, p_val.get("name").?.string),
            .version = try allocator.dupe(u8, p_val.get("version").?.string),
            .kind = try packageKindFromString(p_val.get("kind").?.string),
            .description = if (p_val.get("description")) |d| try allocator.dupe(u8, d.string) else null,
            .readme = if (p_val.get("readme")) |r| try allocator.dupe(u8, r.string) else null,
        };

        if (table.get("interpreter_bundled")) |rb_val| {
            if (rb_val == .table) {
                const rb_table = rb_val.table;
                self.runtime_bundled = .{
                    .name = try allocator.dupe(u8, rb_table.get("name").?.string),
                    .version = try allocator.dupe(u8, rb_table.get("version").?.string),
                    .target = try allocator.dupe(u8, rb_table.get("target").?.string),
                    .artifact_hash = try allocator.dupe(u8, rb_table.get("artifact_hash").?.string),
                };
            }
        }

        errdefer self.deinit(allocator);

        // dependencies
        if (table.get("dependencies")) |deps_val| {
            if (deps_val == .array) {
                var deps = std.ArrayList(StoreDependency).empty;
                for (deps_val.array.items) |dep_val| {
                    const dep = dep_val.table;
                    const role_str = dep.get("role").?.string;
                    const role = try parseDependencyRole(role_str);
                    if (dep.get("registry") != null and dep.get("resolver") != null) return error.DependencyRegistryConflict;
                    const resolver = if (dep.get("registry")) |r|
                        try allocator.dupe(u8, r.string)
                    else if (dep.get("resolver")) |r|
                        try allocator.dupe(u8, r.string)
                    else
                        null;
                    const name = try allocator.dupe(u8, dep.get("name").?.string);
                    const constraint = if (dep.get("constraint")) |c| try allocator.dupe(u8, c.string) else try allocator.dupe(u8, "");
                    const optional = if (dep.get("optional")) |o| o.boolean else false;
                    try deps.append(allocator, .{
                        .name = name,
                        .constraint = constraint,
                        .resolver = resolver,
                        .role = role,
                        .optional = optional,
                    });
                }
                self.dependencies = try deps.toOwnedSlice(allocator);
            }
        }

        // artifacts
        if (table.get("artifacts")) |a_arr| {
            if (a_arr == .array) {
                var list = std.ArrayList(RemoteArtifact).empty;
                for (a_arr.array.items) |a_val| {
                    if (a_val == .table) {
                        const a_table = a_val.table;
                        var art = RemoteArtifact{
                            .url = "",
                            .hash = "",
                            .format = "",
                        };
                        art.id = if (a_table.get("id")) |id| try allocator.dupe(u8, id.string) else try allocator.dupe(u8, "");
                        const kind = a_table.get("kind") orelse return error.MissingArtifactKind;
                        if (kind != .string) return error.InvalidArtifactKind;
                        art.kind = try allocator.dupe(u8, kind.string);
                        art.target = if (a_table.get("target")) |target| try allocator.dupe(u8, target.string) else try allocator.dupe(u8, "");
                        art.lua_abi = if (a_table.get("lua_abi")) |abi| try allocator.dupe(u8, abi.string) else try allocator.dupe(u8, "");
                        art.lua_api = if (a_table.get("lua_api")) |la| try allocator.dupe(u8, la.string) else try allocator.dupe(u8, "");
                        art.runtime = if (a_table.get("runtime")) |rt| try parseArtifactRuntimeValue(allocator, rt) else try allocator.dupe(u8, "");
                        art.runtime_artifact_hash = if (a_table.get("interpreter_artifact_hash")) |rh| try allocator.dupe(u8, rh.string) else try allocator.dupe(u8, "");
                        art.native_compat_required = if (a_table.get("native_compat_required")) |required| blk: {
                            if (required != .boolean) return error.InvalidArtifactNativeCompatRequired;
                            break :blk required.boolean;
                        } else false;

                        art.url = try allocator.dupe(u8, a_table.get("url").?.string);
                        art.hash = try allocator.dupe(u8, a_table.get("hash").?.string);
                        art.source_hash = if (a_table.get("source_hash")) |sh| try allocator.dupe(u8, sh.string) else try allocator.dupe(u8, "");
                        art.source_url = if (a_table.get("source_url")) |su| try allocator.dupe(u8, su.string) else try allocator.dupe(u8, "");
                        art.source_kind = if (a_table.get("source_kind")) |sk| try allocator.dupe(u8, sk.string) else try allocator.dupe(u8, "");
                        art.source_format = if (a_table.get("source_format")) |sf| try allocator.dupe(u8, sf.string) else try allocator.dupe(u8, "");
                        art.format = try allocator.dupe(u8, a_table.get("format").?.string);
                        if (a_table.get("bytes")) |b| art.bytes = @intCast(b.integer) else art.bytes = null;
                        if (a_table.get("recipe_hash")) |rh| art.recipe_hash = try allocator.dupe(u8, rh.string) else art.recipe_hash = "";

                        art.layout = .{ .strip_components = 0 };
                        // materialize
                        const materialize = a_table.get("materialize") orelse return error.MissingArtifactMaterializer;
                        if (materialize != .table) return error.InvalidArtifactMaterializer;
                        art.materialize = try MaterializeConfig.parse(allocator, materialize.table.*);
                        if (materialize.table.get("strip_components")) |sc| art.layout.strip_components = @intCast(sc.integer);

                        // provides
                        art.provides = .{};
                        if (a_table.get("provides")) |prov_val| {
                            if (prov_val == .array) {
                                var runtimes = std.ArrayList(RuntimeProvision).empty;
                                var bins = std.ArrayList(FeatureProvision).empty;
                                var bin_luas = std.ArrayList(FeatureProvision).empty;
                                var headers = std.ArrayList(FeatureProvision).empty;
                                var native_libs = std.ArrayList(FeatureProvision).empty;
                                var lua_modules = std.ArrayList(FeatureProvision).empty;
                                var lua_cmodules = std.ArrayList(FeatureProvision).empty;
                                var scripts = std.ArrayList(FeatureProvision).empty;
                                var assets = std.ArrayList(FeatureProvision).empty;
                                var ballad_plugins = std.ArrayList(FeatureProvision).empty;
                                for (prov_val.array.items) |item| {
                                    const provision = item.table;
                                    const provision_kind = provision.get("kind").?.string;
                                    if (std.mem.eql(u8, provision_kind, "runtime")) {
                                        try runtimes.append(allocator, .{
                                            .name = try allocator.dupe(u8, provision.get("name").?.string),
                                            .version = try allocator.dupe(u8, provision.get("version").?.string),
                                            .abi = try allocator.dupe(u8, provision.get("lua_abi").?.string),
                                        });
                                    } else {
                                        var feature = FeatureProvision{
                                            .name = try allocator.dupe(u8, provision.get("name").?.string),
                                            .path = try allocator.dupe(u8, provision.get("path").?.string),
                                        };
                                        if (provision.get("entry_point")) |ep| {
                                            feature.entry_point = try allocator.dupe(u8, ep.string);
                                        }
                                        if (provision.get("module")) |m| {
                                            feature.module = try allocator.dupe(u8, m.string);
                                        }
                                        if (std.mem.eql(u8, provision_kind, "bin")) {
                                            try bins.append(allocator, feature);
                                        } else if (std.mem.eql(u8, provision_kind, "bin_lua")) {
                                            try bin_luas.append(allocator, feature);
                                        } else if (std.mem.eql(u8, provision_kind, "include") or std.mem.eql(u8, provision_kind, "headers")) {
                                            try headers.append(allocator, feature);
                                        } else if (std.mem.eql(u8, provision_kind, "lib")) {
                                            if (provision.get("linkage")) |linkage| {
                                                feature.linkage = std.meta.stringToEnum(NativeLibraryLinkage, linkage.string) orelse return error.InvalidNativeLibraryLinkage;
                                            }
                                            try native_libs.append(allocator, feature);
                                        } else if (std.mem.eql(u8, provision_kind, "lua_module")) {
                                            try lua_modules.append(allocator, feature);
                                        } else if (std.mem.eql(u8, provision_kind, "lua_cmodule")) {
                                            try lua_cmodules.append(allocator, feature);
                                        } else if (std.mem.eql(u8, provision_kind, "script")) {
                                            try scripts.append(allocator, feature);
                                        } else if (std.mem.eql(u8, provision_kind, "asset")) {
                                            try assets.append(allocator, feature);
                                        } else if (std.mem.eql(u8, provision_kind, "ballad_plugin")) {
                                            try ballad_plugins.append(allocator, feature);
                                        } else {
                                            feature.deinit(allocator);
                                        }
                                    }
                                }
                                art.provides.runtime = try runtimes.toOwnedSlice(allocator);
                                art.provides.bin = try bins.toOwnedSlice(allocator);
                                art.provides.bin_lua = try bin_luas.toOwnedSlice(allocator);
                                art.provides.headers = try headers.toOwnedSlice(allocator);
                                art.provides.native_lib = try native_libs.toOwnedSlice(allocator);
                                art.provides.lua_module = try lua_modules.toOwnedSlice(allocator);
                                art.provides.lua_cmodule = try lua_cmodules.toOwnedSlice(allocator);
                                art.provides.script = try scripts.toOwnedSlice(allocator);
                                art.provides.asset = try assets.toOwnedSlice(allocator);
                                art.provides.ballad_plugin = try ballad_plugins.toOwnedSlice(allocator);
                            }
                        }
                        try list.append(allocator, art);
                    }
                }
                self.artifact = try list.toOwnedSlice(allocator);
            } else return error.InvalidArtifacts;
        } else return error.MissingArtifacts;

        return self;
    }

    pub fn deinit(self: *RemotePackageDescriptor, allocator: std.mem.Allocator) void {
        allocator.free(self.package.name);
        allocator.free(self.package.version);
        if (self.package.description) |d| allocator.free(d);
        if (self.package.readme) |r| allocator.free(r);

        if (self.runtime_bundled) |rb| {
            allocator.free(rb.name);
            allocator.free(rb.version);
            allocator.free(rb.target);
            allocator.free(rb.artifact_hash);
        }

        for (self.compat.runtimes) |rt| allocator.free(rt);
        allocator.free(self.compat.runtimes);

        for (self.dependencies) |dep| {
            var mut_dep = dep;
            mut_dep.deinit(allocator);
        }
        allocator.free(self.dependencies);

        for (self.artifact) |art| {
            var mut_art = art;
            mut_art.deinit(allocator);
        }
        allocator.free(self.artifact);

        if (self.source) |s| {
            allocator.free(s.kind);
            allocator.free(s.format);
            if (s.url) |u| allocator.free(u);
            allocator.free(s.hash);
        }
    }
};

pub const StoreDependency = struct {
    name: []const u8,
    constraint: []const u8 = "",
    resolver: ?[]const u8 = null,
    registry: ?[]const u8 = null,
    role: DependencyRole = .runtime,
    optional: bool = false,

    pub fn deinit(self: *StoreDependency, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.constraint);
        if (self.resolver) |r| allocator.free(r);
        if (self.registry) |r| allocator.free(r);
    }

    /// Reconstruct a raw package-spec string suitable for parsePackageSpec.
    /// Handles both flat-array format (resolver + name + constraint) and
    /// sugar format (constraint may already contain resolver prefix).
    pub fn toSpecString(self: StoreDependency, allocator: std.mem.Allocator) ![]const u8 {
        if (self.registry orelse self.resolver) |registry| {
            if (self.constraint.len > 0 and std.mem.startsWith(u8, self.constraint, registry) and self.constraint.len > registry.len and self.constraint[registry.len] == ':') {
                return try allocator.dupe(u8, self.constraint);
            }
            if (self.constraint.len > 0) {
                return try std.fmt.allocPrint(allocator, "{s}:{s}@{s}", .{ registry, self.name, self.constraint });
            } else {
                return try std.fmt.allocPrint(allocator, "{s}:{s}", .{ registry, self.name });
            }
        } else if (self.constraint.len > 0) {
            if (std.mem.indexOfScalar(u8, self.constraint, ':') != null or std.mem.indexOfScalar(u8, self.constraint, '@') != null) {
                return try allocator.dupe(u8, self.constraint);
            } else {
                return try std.fmt.allocPrint(allocator, "{s}@{s}", .{ self.name, self.constraint });
            }
        } else {
            return try allocator.dupe(u8, self.name);
        }
    }
};

pub const StoreManifest = struct {
    artifact: struct {
        name: []const u8,
        version: []const u8,
        kind: Kind,
        source_hash: []const u8,
        recipe_hash: []const u8,
        artifact_hash: []const u8,
        target: []const u8,
    },
    origin: struct {
        resolver: []const u8 = "",
        source: []const u8 = "",
        source_kind: []const u8 = "",
        source_payload: []const u8 = "",
        source_url: []const u8 = "",
        rockspec: []const u8 = "",
        rockspec_hash: []const u8 = "",
        rockspec_payload: []const u8 = "",
    } = .{},
    compat: struct {
        runtime_version: []const u8 = "", // e.g. lua@5.4.7
        lua_abi: []const u8 = "", // e.g. lua-5.4
        lua_api: []const u8 = "", // e.g. lua54
        runtime_artifact_hash: []const u8 = "", // exact binary identity
    } = .{},

    provides: Provides = .{},
    dependencies: []const StoreDependency = &.{},

    pub fn parse(allocator: std.mem.Allocator, content: []const u8) !StoreManifest {
        var parser = toml.Parser(StoreManifest).init(allocator);
        defer parser.deinit();
        const res = try parser.parseString(content);
        return res.value;
    }

    pub fn deinit(self: *StoreManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.artifact.name);
        allocator.free(self.artifact.version);
        allocator.free(self.artifact.source_hash);
        allocator.free(self.artifact.recipe_hash);
        allocator.free(self.artifact.artifact_hash);
        allocator.free(self.artifact.target);
        allocator.free(self.origin.resolver);
        allocator.free(self.origin.source);
        allocator.free(self.origin.source_kind);
        allocator.free(self.origin.source_payload);
        allocator.free(self.origin.source_url);
        allocator.free(self.origin.rockspec);
        allocator.free(self.origin.rockspec_hash);
        allocator.free(self.origin.rockspec_payload);
        allocator.free(self.compat.runtime_version);
        allocator.free(self.compat.lua_abi);
        allocator.free(self.compat.lua_api);
        allocator.free(self.compat.runtime_artifact_hash);
        self.provides.deinit(allocator);
        for (self.dependencies) |dep| {
            var mut_dep = dep;
            mut_dep.deinit(allocator);
        }
        allocator.free(self.dependencies);
    }

    /// Serializes to TOML.
    /// NOTE: Manual serialization is used here because the 'toml' library struggles with
    /// std.StringArrayHashMapUnmanaged and nested arena-allocated structures.
    /// FUTURE: This could be refactored to use DTOs (Data Transfer Objects) that match
    /// the library's expected structure more closely if automated serialization is desired.
    pub fn serialize(self: StoreManifest, allocator: std.mem.Allocator, writer: anytype) !void {
        _ = allocator;
        try writer.print("[artifact]\n", .{});
        try writer.print("name = \"{s}\"\n", .{self.artifact.name});
        try writer.print("version = \"{s}\"\n", .{self.artifact.version});
        try writer.print("kind = \"{s}\"\n", .{@tagName(self.artifact.kind)});
        try writer.print("source_hash = \"{s}\"\n", .{self.artifact.source_hash});
        try writer.print("recipe_hash = \"{s}\"\n", .{self.artifact.recipe_hash});
        try writer.print("artifact_hash = \"{s}\"\n", .{self.artifact.artifact_hash});
        try writer.print("target = \"{s}\"\n", .{self.artifact.target});

        try writer.print("\n[origin]\n", .{});
        try writer.print("resolver = \"{s}\"\n", .{self.origin.resolver});
        try writer.print("source = \"{s}\"\n", .{self.origin.source});
        if (self.origin.source_kind.len > 0) try writer.print("source_kind = \"{s}\"\n", .{self.origin.source_kind});
        if (self.origin.source_payload.len > 0) try writer.print("source_payload = \"{s}\"\n", .{self.origin.source_payload});
        if (self.origin.source_url.len > 0) try writer.print("source_url = \"{s}\"\n", .{self.origin.source_url});
        if (self.origin.rockspec.len > 0) try writer.print("rockspec = \"{s}\"\n", .{self.origin.rockspec});
        if (self.origin.rockspec_hash.len > 0) try writer.print("rockspec_hash = \"{s}\"\n", .{self.origin.rockspec_hash});
        if (self.origin.rockspec_payload.len > 0) try writer.print("rockspec_payload = \"{s}\"\n", .{self.origin.rockspec_payload});

        try writer.print("\n[compat]\n", .{});
        try writer.print("interpreter_version = \"{s}\"\n", .{self.compat.runtime_version});
        try writer.print("lua_abi = \"{s}\"\n", .{self.compat.lua_abi});
        try writer.print("interpreter_artifact_hash = \"{s}\"\n", .{self.compat.runtime_artifact_hash});

        try writer.print("\n[provides]\n", .{});
        try self.serializeProvides(self.provides, writer);

        for (self.dependencies) |dep| {
            try writer.print("\n[[dependencies]]\n", .{});
            try writer.print("name = \"{s}\"\n", .{dep.name});
            try writer.print("constraint = \"{s}\"\n", .{dep.constraint});
            if (dep.resolver) |r| try writer.print("resolver = \"{s}\"\n", .{r});
            try writer.print("role = \"{s}\"\n", .{@tagName(dep.role)});
            if (dep.optional) try writer.print("optional = true\n", .{});
        }
    }

    fn serializeProvides(self: StoreManifest, provs: Provides, writer: anytype) !void {
        _ = self;
        if (provs.runtime.len > 0) {
            try writer.print("runtime = [", .{});
            for (provs.runtime, 0..) |rt, i| {
                if (i > 0) try writer.print(", ", .{});
                try writer.print("{{ name = \"{s}\", version = \"{s}\", abi = \"{s}\" }}", .{ rt.name, rt.version, rt.abi });
            }
            try writer.print("]\n", .{});
        }
        inline for (.{ "bin", "bin_lua", "headers", "native_lib", "lua_module", "lua_cmodule", "script", "asset", "ballad_plugin" }) |field| {
            const list = @field(provs, field);
            if (list.len > 0) {
                try writer.print("{s} = [", .{field});
                for (list, 0..) |p, i| {
                    if (i > 0) try writer.print(", ", .{});
                    try writer.print("{{ name = \"{s}\", path = \"{s}\"", .{ p.name, p.path });
                    if (p.entry_point) |ep| {
                        try writer.print(", entry_point = \"{s}\"", .{ep});
                    }
                    if (p.module) |m| {
                        try writer.print(", module = \"{s}\"", .{m});
                    }
                    if (comptime std.mem.eql(u8, field, "native_lib")) {
                        if (p.linkage != .unknown) try writer.print(", linkage = \"{s}\"", .{@tagName(p.linkage)});
                    }
                    try writer.print(" }}", .{});
                }
                try writer.print("]\n", .{});
            }
        }
    }
};

pub const MoonstoneToml = struct {
    pub const TidyScriptOrder = enum {
        lexicographic,
        preserve,

        pub fn fromString(value: []const u8) ?TidyScriptOrder {
            if (std.mem.eql(u8, value, "lexicographic")) return .lexicographic;
            if (std.mem.eql(u8, value, "preserve")) return .preserve;
            return null;
        }

        pub fn asString(self: TidyScriptOrder) []const u8 {
            return switch (self) {
                .lexicographic => "lexicographic",
                .preserve => "preserve",
            };
        }
    };

    pub const Tidy = struct {
        scripts: TidyScriptOrder = .lexicographic,
        on_script_mutation: bool = true,

        pub fn isDefault(self: Tidy) bool {
            return self.scripts == .lexicographic and self.on_script_mutation;
        }
    };

    manifest_version: u32 = 2,
    package: struct {
        name: []const u8,
        version: []const u8,
        kind: Kind,
        description: ?[]const u8 = null,
        readme: ?[]const u8 = null,
    },
    runtime: struct {
        name: []const u8,
        version: []const u8,
        abi: []const u8,
    },
    origin: ?Origin = null,
    dependencies: std.ArrayListUnmanaged(StoreDependency) = .empty,
    scripts: std.ArrayListUnmanaged(script_mod.ScriptDefinition) = .empty,
    tidy: Tidy = .{},
    registries: std.StringArrayHashMapUnmanaged(RegistryConfig) = .{},
    orbits: std.ArrayListUnmanaged(OrbitConfig) = .empty,
    build: ?Build = null,

    pub const BuildEnvVar = struct {
        value: ?[]const u8 = null,
        from: ?[]const u8 = null,
        optional: bool = false,
        default: ?[]const u8 = null,
    };

    pub const Build = struct {
        env: std.StringArrayHashMapUnmanaged(BuildEnvVar) = .{},
    };

    pub const OrbitConfig = struct {
        name: []const u8,
        path: []const u8,
    };

    pub const Origin = struct {
        kind: []const u8,
        url: []const u8,
        revision: ?[]const u8 = null,
        hash: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator) MoonstoneToml {
        _ = allocator;
        return .{
            .package = undefined,
            .runtime = .{ .name = "", .version = "", .abi = "" },
        };
    }

    pub fn findScript(self: *const MoonstoneToml, name: []const u8) ?*const script_mod.ScriptDefinition {
        for (self.scripts.items) |*script| if (std.mem.eql(u8, script.name, name)) return script;
        return null;
    }

    pub fn setScript(self: *MoonstoneToml, allocator: std.mem.Allocator, name: []const u8, command: []const u8) !void {
        if (!script_mod.isValidName(name)) return error.InvalidScriptName;
        if (command.len == 0) return error.InvalidScriptCommand;

        for (self.scripts.items) |*definition| {
            if (!std.mem.eql(u8, definition.name, name)) continue;
            allocator.free(definition.command);
            definition.command = try allocator.dupe(u8, command);
            return;
        }

        const definition_name = try allocator.dupe(u8, name);
        errdefer allocator.free(definition_name);
        try self.scripts.append(allocator, .{
            .name = definition_name,
            .command = try allocator.dupe(u8, command),
        });
    }

    pub fn resolveBuildEnv(self: *const MoonstoneToml, allocator: std.mem.Allocator, env_map: *std.process.Environ.Map) ![]const EnvPair {
        if (self.build) |*build| {
            if (build.env.count() == 0) return &.{};
            var res = std.ArrayList(EnvPair).empty;
            var it = build.env.iterator();
            while (it.next()) |entry| {
                var val: ?[]const u8 = null;
                if (entry.value_ptr.value) |v| {
                    val = try allocator.dupe(u8, v);
                } else if (entry.value_ptr.from) |f| {
                    if (env_map.get(f)) |v| {
                        val = try allocator.dupe(u8, v);
                    } else if (entry.value_ptr.default) |d| {
                        val = try allocator.dupe(u8, d);
                    } else if (!entry.value_ptr.optional) {
                        std.debug.print("Error: Missing required build environment variable '{s}' (from '{s}')\n", .{ entry.key_ptr.*, f });
                        return error.MissingBuildEnvVar;
                    }
                }
                if (val) |v| {
                    try res.append(allocator, .{ .key = try allocator.dupe(u8, entry.key_ptr.*), .value = v });
                }
            }
            return try res.toOwnedSlice(allocator);
        }
        return &.{};
    }

    pub fn parse(allocator: std.mem.Allocator, content: []const u8) !MoonstoneToml {
        var parser = toml.Parser(toml.Table).init(allocator);
        defer parser.deinit();
        var res = try parser.parseString(content);
        defer res.deinit();
        const table = res.value;

        var self = MoonstoneToml.init(allocator);
        self.manifest_version = 1;
        if (table.get("manifest_version")) |version_value| {
            if (version_value != .integer) return error.InvalidManifestVersion;
            self.manifest_version = @intCast(version_value.integer);
        }
        if (self.manifest_version != 1 and self.manifest_version != 2) return error.UnsupportedManifestVersion;
        const package_val = table.get("package") orelse return error.MissingPackageSection;
        if (package_val != .table) return error.InvalidPackageSection;
        const p_val = package_val.table;
        const r_val = if (table.get("interpreter") orelse table.get("runtime")) |runtime_val| blk: {
            if (runtime_val != .table) return error.InvalidRuntimeSection;
            break :blk runtime_val.table;
        } else null;

        const package_name = p_val.get("name") orelse return error.MissingPackageName;
        if (package_name != .string) return error.InvalidPackageName;
        const package_version = p_val.get("version") orelse return error.MissingPackageVersion;
        if (package_version != .string) return error.InvalidPackageVersion;
        const package_kind = p_val.get("kind") orelse return error.MissingPackageKind;
        if (package_kind != .string) return error.InvalidPackageKind;
        self.package = .{
            .name = try allocator.dupe(u8, package_name.string),
            .version = try allocator.dupe(u8, package_version.string),
            .kind = try packageKindFromString(package_kind.string),
            .description = if (p_val.get("description")) |d| try allocator.dupe(u8, d.string) else null,
            .readme = if (p_val.get("readme")) |r| try allocator.dupe(u8, r.string) else null,
        };
        const runtime_name = if (r_val) |runtime| blk: {
            const value = runtime.get("name") orelse break :blk "lua";
            if (value != .string) return error.InvalidRuntimeName;
            break :blk value.string;
        } else "";
        const runtime_version = if (r_val) |runtime| blk: {
            const value = runtime.get("version") orelse break :blk "5.4";
            if (value != .string) return error.InvalidRuntimeVersion;
            break :blk value.string;
        } else "";
        const runtime_abi = if (r_val) |runtime|
            if (runtime.get("abi")) |a| blk: {
                if (a != .string) return error.InvalidRuntimeAbi;
                break :blk try allocator.dupe(u8, a.string);
            } else try inferRuntimeAbi(allocator, runtime_name, runtime_version)
        else
            try allocator.dupe(u8, "");

        self.runtime = .{
            .name = try allocator.dupe(u8, runtime_name),
            .version = try allocator.dupe(u8, runtime_version),
            .abi = runtime_abi,
        };

        if (table.get("origin")) |origin_val| {
            if (origin_val != .table) return error.InvalidOriginSection;
            const origin_kind = origin_val.table.get("kind") orelse return error.MissingOriginKind;
            if (origin_kind != .string) return error.InvalidOriginKind;
            const origin_url = origin_val.table.get("url") orelse return error.MissingOriginUrl;
            if (origin_url != .string) return error.InvalidOriginUrl;
            const revision = if (origin_val.table.get("revision")) |value| blk: {
                if (value != .string) return error.InvalidOriginRevision;
                break :blk try allocator.dupe(u8, value.string);
            } else null;
            const hash = if (origin_val.table.get("hash")) |value| blk: {
                if (value != .string) return error.InvalidOriginHash;
                break :blk try allocator.dupe(u8, value.string);
            } else null;
            self.origin = .{
                .kind = try allocator.dupe(u8, origin_kind.string),
                .url = try allocator.dupe(u8, origin_url.string),
                .revision = revision,
                .hash = hash,
            };
        }

        if (table.get("build")) |b| {
            if (b == .table) {
                var build_cfg = Build{};
                if (b.table.get("env")) |e| {
                    if (e == .table) {
                        var it = e.table.iterator();
                        while (it.next()) |entry| {
                            var env_var = BuildEnvVar{};
                            switch (entry.value_ptr.*) {
                                .string => |s| env_var.value = try allocator.dupe(u8, s),
                                .table => |t| {
                                    if (t.get("from")) |f| if (f == .string) {
                                        env_var.from = try allocator.dupe(u8, f.string);
                                    };
                                    if (t.get("default")) |d| if (d == .string) {
                                        env_var.default = try allocator.dupe(u8, d.string);
                                    };
                                    if (t.get("optional")) |o| if (o == .boolean) {
                                        env_var.optional = o.boolean;
                                    };
                                },
                                else => continue,
                            }
                            try build_cfg.env.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), env_var);
                        }
                    }
                }
                self.build = build_cfg;
            }
        }

        self.tidy = .{};
        if (table.get("manifest")) |manifest_value| {
            if (manifest_value != .table) return error.InvalidManifestSettings;
            if (manifest_value.table.get("tidy")) |tidy_value| {
                if (tidy_value != .table) return error.InvalidManifestTidyPolicy;
                if (tidy_value.table.get("scripts")) |scripts_value| {
                    if (scripts_value != .string) return error.InvalidManifestTidyPolicy;
                    self.tidy.scripts = TidyScriptOrder.fromString(scripts_value.string) orelse return error.InvalidManifestTidyPolicy;
                }
                if (tidy_value.table.get("on_script_mutation")) |mutation_value| {
                    if (mutation_value != .boolean) return error.InvalidManifestTidyPolicy;
                    self.tidy.on_script_mutation = mutation_value.boolean;
                }
            }
        }

        self.dependencies = .empty;
        if (table.get("dependencies")) |deps_val| {
            if (deps_val == .array) {
                for (deps_val.array.items) |dep_val| {
                    const dep = dep_val.table;
                    const role_str = if (dep.get("role")) |r| r.string else "runtime";
                    const role = try parseDependencyRole(role_str);
                    if (dep.get("resolver") != null) return error.DependencyResolverSyntaxUnsupported;
                    const registry = if (dep.get("registry")) |r| try allocator.dupe(u8, r.string) else null;
                    const name = try allocator.dupe(u8, dep.get("name").?.string);
                    const constraint = if (dep.get("constraint")) |c| try allocator.dupe(u8, c.string) else try allocator.dupe(u8, "");
                    const optional = if (dep.get("optional")) |o| o.boolean else false;
                    try self.dependencies.append(allocator, .{
                        .name = name,
                        .constraint = constraint,
                        .registry = registry,
                        .role = role,
                        .optional = optional,
                    });
                }
            } else if (deps_val == .table) {
                // Support authoring sugar [dependencies.<role>]
                if (deps_val.table.get("dependency") != null) return error.LegacyDependencyRole;
                inline for (.{ "dev", "tool", "runtime", "helper", "external", "peer", "optional" }) |role_name| {
                    if (deps_val.table.get(role_name)) |v| {
                        if (v == .table) {
                            var it = v.table.iterator();
                            while (it.next()) |entry| {
                                const role = try parseDependencyRole(role_name);
                                try self.dependencies.append(allocator, .{
                                    .name = try allocator.dupe(u8, entry.key_ptr.*),
                                    .constraint = try allocator.dupe(u8, entry.value_ptr.string),
                                    .role = role,
                                });
                            }
                        }
                    }
                }

                // Authoring aliases
                const alias_mappings = .{
                    .{ .field = "vendor-exec", .role = DependencyRole.helper },
                    .{ .field = "interpreter-exec", .role = DependencyRole.helper },
                    .{ .field = "runtime-exec", .role = DependencyRole.helper },
                };
                inline for (alias_mappings) |mapping| {
                    if (deps_val.table.get(mapping.field)) |v| {
                        if (v == .table) {
                            var it = v.table.iterator();
                            while (it.next()) |entry| {
                                try self.dependencies.append(allocator, .{
                                    .name = try allocator.dupe(u8, entry.key_ptr.*),
                                    .constraint = try allocator.dupe(u8, entry.value_ptr.string),
                                    .role = mapping.role,
                                });
                            }
                        }
                    }
                }

                // Legacy support
                const legacy_mappings = .{
                    .{ .field = "libs", .role = DependencyRole.runtime },
                    .{ .field = "bins", .role = DependencyRole.helper },
                    .{ .field = "dev_libs", .role = DependencyRole.dev },
                    .{ .field = "dev_bins", .role = DependencyRole.tool },
                };
                inline for (legacy_mappings) |mapping| {
                    if (deps_val.table.get(mapping.field)) |v| {
                        std.debug.print("WARNING: [dependencies.{s}] is deprecated. Please use [dependencies.{s}] instead.\n", .{ mapping.field, mapping.role.toString() });
                        if (v == .table) {
                            var it = v.table.iterator();
                            while (it.next()) |entry| {
                                try self.dependencies.append(allocator, .{
                                    .name = try allocator.dupe(u8, entry.key_ptr.*),
                                    .constraint = try allocator.dupe(u8, entry.value_ptr.string),
                                    .role = mapping.role,
                                });
                            }
                        }
                    }
                }
            }
        }

        if (table.get("commands") != null) return error.LegacyScriptSyntax;
        if (table.get("script") != null) return error.UnsupportedComplexScriptSyntax;
        if (self.manifest_version == 1 and table.get("scripts") != null) return error.ManifestVersionRequired;
        self.scripts = .empty;
        if (table.get("scripts")) |scripts_value| {
            if (scripts_value != .table) return error.InvalidScriptSection;
            var names = scripts_value.table.iterator();
            while (names.next()) |name_entry| {
                const name = name_entry.key_ptr.*;
                if (!script_mod.isValidName(name)) return error.InvalidScriptName;
                if (name_entry.value_ptr.* != .string) return error.InvalidScriptCommand;

                var definition = script_mod.ScriptDefinition{
                    .name = try allocator.dupe(u8, name),
                    .command = try allocator.dupe(u8, name_entry.value_ptr.string),
                };
                errdefer definition.deinit(allocator);
                try definition.validate();
                try self.scripts.append(allocator, definition);
            }
        }

        self.registries = .{};
        if (table.get("registries")) |reg_val| {
            try extractRegistriesFromToml(allocator, reg_val, &self.registries);
        }

        self.orbits = .empty;
        if (table.get("orbits")) |orbits_val| {
            if (orbits_val == .table) {
                if (orbits_val.table.get("member")) |members_val| {
                    if (members_val == .array) {
                        for (members_val.array.items) |member_val| {
                            if (member_val == .table) {
                                const name_val = member_val.table.get("name") orelse return error.OrbitMissingName;
                                if (name_val != .string) return error.OrbitInvalidName;
                                const path_val = member_val.table.get("path") orelse return error.OrbitMissingPath;
                                if (path_val != .string) return error.OrbitInvalidPath;

                                try self.orbits.append(allocator, .{
                                    .name = try allocator.dupe(u8, name_val.string),
                                    .path = try allocator.dupe(u8, path_val.string),
                                });
                            }
                        }
                    }
                }
            }
        }

        return self;
    }

    pub fn deinit(self: *MoonstoneToml, allocator: std.mem.Allocator) void {
        allocator.free(self.package.name);
        allocator.free(self.package.version);
        if (self.package.description) |d| allocator.free(d);
        if (self.package.readme) |readme| allocator.free(readme);
        allocator.free(self.runtime.name);
        allocator.free(self.runtime.version);
        allocator.free(self.runtime.abi);
        if (self.origin) |origin| {
            allocator.free(origin.kind);
            allocator.free(origin.url);
            if (origin.revision) |revision| allocator.free(revision);
            if (origin.hash) |hash| allocator.free(hash);
        }

        for (self.dependencies.items) |dep| {
            var mut_dep = dep;
            mut_dep.deinit(allocator);
        }
        self.dependencies.deinit(allocator);

        for (self.scripts.items) |*script| script.deinit(allocator);
        self.scripts.deinit(allocator);

        var reg_it = self.registries.iterator();
        while (reg_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.registries.deinit(allocator);

        if (self.build) |*build| {
            var build_env_it = build.env.iterator();
            while (build_env_it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                if (entry.value_ptr.value) |value| allocator.free(value);
                if (entry.value_ptr.from) |from| allocator.free(from);
                if (entry.value_ptr.default) |default| allocator.free(default);
            }
            build.env.deinit(allocator);
        }
        for (self.orbits.items) |o| {
            allocator.free(o.name);
            allocator.free(o.path);
        }
        self.orbits.deinit(allocator);
    }

    /// Serializes to TOML.
    /// NOTE: Manual serialization is used here because the 'toml' library struggles with
    /// std.StringArrayHashMapUnmanaged and nested arena-allocated structures.
    /// FUTURE: This could be refactored to use DTOs (Data Transfer Objects) that match
    /// the library's expected structure more closely if automated serialization is desired.
    pub fn serialize(self: MoonstoneToml, allocator: std.mem.Allocator, writer: anytype) !void {
        try writer.print("manifest_version = {d}\n\n", .{self.manifest_version});
        try writer.print("[package]\n", .{});
        try writer.print("name = ", .{});
        try writeTomlString(writer, self.package.name);
        try writer.print("\nversion = ", .{});
        try writeTomlString(writer, self.package.version);
        try writer.print("\nkind = ", .{});
        try writeTomlString(writer, @tagName(self.package.kind));
        if (self.package.description) |d| {
            try writer.print("\ndescription = ", .{});
            try writeTomlString(writer, d);
        }
        if (self.package.readme) |readme| {
            try writer.print("\nreadme = ", .{});
            try writeTomlString(writer, readme);
        }
        try writer.print("\n", .{});

        try writer.print("\n[interpreter]\n", .{});
        try writer.print("name = ", .{});
        try writeTomlString(writer, self.runtime.name);
        try writer.print("\nversion = ", .{});
        try writeTomlString(writer, self.runtime.version);
        try writer.print("\nabi = ", .{});
        try writeTomlString(writer, self.runtime.abi);
        try writer.print("\n", .{});

        if (!self.tidy.isDefault()) {
            try writer.print("\n[manifest.tidy]\nscripts = ", .{});
            try writeTomlString(writer, self.tidy.scripts.asString());
            try writer.print("\non_script_mutation = {s}\n", .{if (self.tidy.on_script_mutation) "true" else "false"});
        }

        if (self.origin) |origin| {
            try writer.print("\n[origin]\nkind = ", .{});
            try writeTomlString(writer, origin.kind);
            try writer.print("\nurl = ", .{});
            try writeTomlString(writer, origin.url);
            if (origin.revision) |revision| {
                try writer.print("\nrevision = ", .{});
                try writeTomlString(writer, revision);
            }
            if (origin.hash) |hash| {
                try writer.print("\nhash = ", .{});
                try writeTomlString(writer, hash);
            }
            try writer.print("\n", .{});
        }

        if (self.scripts.items.len > 0) {
            try writer.print("\n[scripts]\n", .{});
            for (self.scripts.items) |script| {
                try writer.print("{s} = ", .{script.name});
                try writeTomlCommand(writer, script.command);
                try writer.print("\n", .{});
            }
        }

        for (self.orbits.items) |orbit| {
            try writer.print("\n[[orbits.member]]\n", .{});
            try writer.print("name = ", .{});
            try writeTomlString(writer, orbit.name);
            try writer.print("\npath = ", .{});
            try writeTomlString(writer, orbit.path);
            try writer.print("\n", .{});
        }

        if (self.build) |build| {
            if (build.env.count() > 0) {
                const BuildEnvEntry = struct {
                    key: []const u8,
                    value: BuildEnvVar,
                };
                var entries = std.ArrayList(BuildEnvEntry).empty;
                defer entries.deinit(allocator);

                var it = build.env.iterator();
                while (it.next()) |entry| {
                    try entries.append(allocator, .{
                        .key = entry.key_ptr.*,
                        .value = entry.value_ptr.*,
                    });
                }
                std.mem.sort(BuildEnvEntry, entries.items, {}, struct {
                    fn lessThan(_: void, left: BuildEnvEntry, right: BuildEnvEntry) bool {
                        return std.mem.order(u8, left.key, right.key) == .lt;
                    }
                }.lessThan);

                try writer.print("\n[build.env]\n", .{});
                for (entries.items) |entry| {
                    try writeTomlString(writer, entry.key);
                    try writer.print(" = ", .{});
                    if (entry.value.value) |value| {
                        try writeTomlString(writer, value);
                    } else {
                        try writer.writeAll("{ ");
                        var wrote_field = false;
                        if (entry.value.from) |from| {
                            try writer.print("from = ", .{});
                            try writeTomlString(writer, from);
                            wrote_field = true;
                        }
                        if (entry.value.optional) {
                            if (wrote_field) try writer.print(", ", .{});
                            try writer.print("optional = true", .{});
                            wrote_field = true;
                        }
                        if (entry.value.default) |default| {
                            if (wrote_field) try writer.print(", ", .{});
                            try writer.print("default = ", .{});
                            try writeTomlString(writer, default);
                        }
                        try writer.writeAll(" }");
                    }
                    try writer.print("\n", .{});
                }
            }
        }

        if (self.registries.count() > 0) {
            const RegistryEntry = struct {
                key: []const u8,
                value: RegistryConfig,
            };
            var entries = std.ArrayList(RegistryEntry).empty;
            defer entries.deinit(allocator);

            var it = self.registries.iterator();
            while (it.next()) |entry| {
                try entries.append(allocator, .{
                    .key = entry.key_ptr.*,
                    .value = entry.value_ptr.*,
                });
            }
            std.mem.sort(RegistryEntry, entries.items, {}, struct {
                fn lessThan(_: void, left: RegistryEntry, right: RegistryEntry) bool {
                    return std.mem.order(u8, left.key, right.key) == .lt;
                }
            }.lessThan);

            for (entries.items) |entry| {
                try writer.print("\n[[registries]]\nname = ", .{});
                try writeTomlString(writer, entry.key);
                try writer.print("\nresolver = ", .{});
                try writeTomlString(writer, entry.value.resolver);
                try writer.print("\n", .{});
                if (entry.value.url) |url| {
                    try writer.print("url = ", .{});
                    try writeTomlString(writer, url);
                    try writer.print("\n", .{});
                }
                if (entry.value.path) |path| {
                    try writer.print("path = ", .{});
                    try writeTomlString(writer, path);
                    try writer.print("\n", .{});
                }
                try writer.print("priority = {d}\n", .{entry.value.priority});
            }
        }

        const ordered_dependencies = try allocator.dupe(StoreDependency, self.dependencies.items);
        defer allocator.free(ordered_dependencies);
        std.mem.sort(StoreDependency, ordered_dependencies, {}, dependencyLessThan);

        // Dependencies at the bottom
        for (ordered_dependencies) |dep| {
            try writer.print("\n[[dependencies]]\n", .{});
            try writer.print("name = ", .{});
            try writeTomlString(writer, dep.name);
            try writer.print("\nconstraint = ", .{});
            try writeTomlString(writer, dep.constraint);
            if (dep.registry) |r| {
                try writer.print("\nregistry = ", .{});
                try writeTomlString(writer, r);
            }
            try writer.print("\nrole = \"{s}\"\n", .{dep.role.toString()});
            if (dep.optional) try writer.print("optional = true\n", .{});
        }
    }

    fn writeTomlString(writer: anytype, value: []const u8) !void {
        try writer.writeByte('"');
        for (value) |ch| {
            switch (ch) {
                '\\' => try writer.writeAll("\\\\"),
                '"' => try writer.writeAll("\\\""),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(ch),
            }
        }
        try writer.writeByte('"');
    }

    fn writeTomlCommand(writer: anytype, value: []const u8) !void {
        if (std.mem.indexOfScalar(u8, value, '\n') == null or std.mem.startsWith(u8, value, "\n") or std.mem.indexOf(u8, value, "\"\"\"") != null) {
            return writeTomlString(writer, value);
        }
        try writer.writeAll("\"\"\"\n");
        try writer.writeAll(value);
        if (!std.mem.endsWith(u8, value, "\n")) try writer.writeByte('\n');
        try writer.writeAll("\"\"\"");
    }

    fn dependencyLessThan(_: void, left: StoreDependency, right: StoreDependency) bool {
        const left_role_rank = dependencyRoleRank(left.role);
        const right_role_rank = dependencyRoleRank(right.role);
        if (left_role_rank != right_role_rank) return left_role_rank < right_role_rank;

        if (std.mem.order(u8, left.name, right.name) != .eq) {
            return std.mem.order(u8, left.name, right.name) == .lt;
        }

        const left_resolver = left.resolver orelse "";
        const right_resolver = right.resolver orelse "";
        if (std.mem.order(u8, left_resolver, right_resolver) != .eq) {
            return std.mem.order(u8, left_resolver, right_resolver) == .lt;
        }

        if (std.mem.order(u8, left.constraint, right.constraint) != .eq) {
            return std.mem.order(u8, left.constraint, right.constraint) == .lt;
        }

        return !left.optional and right.optional;
    }

    fn dependencyRoleRank(role: DependencyRole) u8 {
        return switch (role) {
            .tool => 0,
            .dev => 1,
            .build => 2,
            .runtime => 3,
            .helper => 4,
            .external => 5,
            .optional => 6,
        };
    }

    pub fn add_dependency(self: *MoonstoneToml, allocator: std.mem.Allocator, name: []const u8, spec: []const u8, role: DependencyRole, optional: bool) !void {
        try self.add_dependency_with_registry(allocator, name, spec, role, optional, null);
    }

    pub fn add_dependency_with_registry(self: *MoonstoneToml, allocator: std.mem.Allocator, name: []const u8, spec: []const u8, role: DependencyRole, optional: bool, registry: ?[]const u8) !void {
        // Check if it already exists, replace it
        for (self.dependencies.items) |*dep| {
            if (std.mem.eql(u8, dep.name, name)) {
                allocator.free(dep.constraint);
                dep.constraint = try allocator.dupe(u8, spec);
                if (dep.registry) |r| allocator.free(r);
                dep.registry = if (registry) |r| try allocator.dupe(u8, r) else null;
                dep.role = role;
                dep.optional = optional;
                return;
            }
        }

        try self.dependencies.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .constraint = try allocator.dupe(u8, spec),
            .registry = if (registry) |r| try allocator.dupe(u8, r) else null,
            .role = role,
            .optional = optional,
        });
    }

    pub fn runtimeName(self: MoonstoneToml) []const u8 {
        return self.runtime.name;
    }

    pub fn runtimeVersion(self: MoonstoneToml) []const u8 {
        return self.runtime.version;
    }

    pub fn runtimeConstraint(self: MoonstoneToml) []const u8 {
        return self.runtime.version;
    }

    pub fn runtimeAbi(self: MoonstoneToml) []const u8 {
        return self.runtime.abi;
    }
};

pub fn runtimeNameFromSpec(spec: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, spec, '@')) |pos| return spec[0..pos];
    if (std.mem.startsWith(u8, spec, "luajit")) return "luajit";
    if (std.mem.startsWith(u8, spec, "love")) return "love";
    return "lua";
}

pub fn runtimeVersionFromSpec(spec: []const u8) []const u8 {
    var version = if (std.mem.indexOfScalar(u8, spec, '@')) |pos| spec[pos + 1 ..] else spec;
    while (version.len > 0 and (version[0] == '^' or version[0] == '~' or version[0] == '=')) version = version[1..];
    if (std.mem.startsWith(u8, version, "lua")) version = version[3..];
    return version;
}

pub fn inferRuntimeAbi(allocator: std.mem.Allocator, runtime_name: []const u8, runtime_version: []const u8) ![]const u8 {
    if (std.mem.eql(u8, runtime_name, "luajit") or std.mem.eql(u8, runtime_name, "love")) {
        return try allocator.dupe(u8, "5.1");
    }

    var version = runtimeVersionFromSpec(runtime_version);
    if (version.len >= 3 and std.ascii.isDigit(version[0]) and version[1] == '.' and std.ascii.isDigit(version[2])) {
        return try allocator.dupe(u8, version[0..3]);
    }
    if (version.len >= 2 and std.ascii.isDigit(version[0]) and std.ascii.isDigit(version[1])) {
        return try std.fmt.allocPrint(allocator, "{c}.{c}", .{ version[0], version[1] });
    }
    return try allocator.dupe(u8, "5.4");
}

pub const RegistryConfig = struct {
    resolver: []const u8,
    url: ?[]const u8 = null,
    path: ?[]const u8 = null,
    priority: i32 = 0,

    pub fn deinit(self: RegistryConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.resolver);
        if (self.url) |u| allocator.free(u);
        if (self.path) |p| allocator.free(p);
    }
};

fn isReservedRegistryName(name: []const u8) bool {
    const reserved = [_][]const u8{ "moonstone", "rocks", "default", "path", "link", "artifact" };
    for (reserved) |value| if (std.mem.eql(u8, name, value)) return true;
    return false;
}

/// Extract canonical `[[registries]]` declarations into name -> RegistryConfig.
pub fn extractRegistriesFromToml(
    allocator: std.mem.Allocator,
    registries_value: toml.Value,
    out_map: *std.StringArrayHashMapUnmanaged(RegistryConfig),
) !void {
    switch (registries_value) {
        .table => return error.RegistryTableSyntaxUnsupported,
        .array => |ar| {
            // Array-table syntax: [[registries]]
            for (ar.items) |item| {
                if (item != .table) continue;
                const rt = item.table;
                const name_v = rt.get("name") orelse continue;
                const resolver_v = rt.get("resolver") orelse return error.RegistryResolverRequired;
                const reg_name = name_v.string;
                if (isReservedRegistryName(reg_name)) return error.ReservedRegistryName;
                if (rt.get("token") != null or rt.get("credential_provider") != null) return error.RegistryAuthenticationUnsupported;
                try out_map.put(allocator, try allocator.dupe(u8, reg_name), .{
                    .resolver = try allocator.dupe(u8, resolver_v.string),
                    .url = if (rt.get("url")) |u| try allocator.dupe(u8, u.string) else null,
                    .path = if (rt.get("path")) |p| try allocator.dupe(u8, p.string) else null,
                    .priority = if (rt.get("priority")) |p| @intCast(p.integer) else 0,
                });
            }
        },
        else => {},
    }
}

pub const Recipe = struct {
    schema_version: u32 = 2,
    name: []const u8,
    version: []const u8,
    source_hash: []const u8,
    materializer_kind: []const u8,
    materializer_version: []const u8,
    lua_version: []const u8, // e.g. lua@5.4.7
    lua_abi: []const u8, // e.g. lua-5.4
    runtime_artifact_hash: []const u8, // exact binary identity
    target: []const u8,
    dependency_artifact_hashes: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    command: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    env: []const EnvPair = &.{},
    output_collection_rules: ?[]const u8 = null,

    pub fn deinit(self: *Recipe, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.source_hash);
        allocator.free(self.materializer_kind);
        allocator.free(self.materializer_version);
        allocator.free(self.lua_version);
        allocator.free(self.lua_abi);
        allocator.free(self.runtime_artifact_hash);
        allocator.free(self.target);

        var it = self.dependency_artifact_hashes.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.dependency_artifact_hashes.deinit(allocator);

        if (self.command) |c| allocator.free(c);
        for (self.args) |a| allocator.free(a);
        allocator.free(self.args);
        for (self.env) |e| {
            allocator.free(e.key);
            allocator.free(e.value);
        }
        allocator.free(self.env);
        if (self.output_collection_rules) |o| allocator.free(o);
    }
};

test "MoonstoneToml parse allows missing runtime for interpreter set repair" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "repairable"
        \\version = "0.1.0"
        \\kind = "script"
    ;

    var manifest = try MoonstoneToml.parse(allocator, toml_text);
    defer manifest.deinit(allocator);

    try std.testing.expectEqualStrings("", manifest.runtime.name);
    try std.testing.expectEqualStrings("", manifest.runtime.version);
    try std.testing.expectEqualStrings("", manifest.runtime.abi);
}

test "MoonstoneToml parse rejects non-table runtime" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "invalid-runtime"
        \\version = "0.1.0"
        \\kind = "script"
        \\runtime = "lua@5.4"
    ;

    try std.testing.expectError(error.InvalidRuntimeSection, MoonstoneToml.parse(allocator, toml_text));
}

test "MoonstoneToml parse rejects missing package section" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[runtime]
        \\name = "lua"
        \\version = "5.4"
    ;

    try std.testing.expectError(error.MissingPackageSection, MoonstoneToml.parse(allocator, toml_text));
}

test "MoonstoneToml parse rejects package kind tool" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "tool-kind"
        \\version = "0.1.0"
        \\kind = "tool"
    ;

    try std.testing.expectError(error.InvalidPackageKind, MoonstoneToml.parse(allocator, toml_text));
}

test "MoonstoneToml serializes simple dependencies as flat runtime roles" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "roles"
        \\version = "0.1.0"
        \\kind = "script"
        \\
        \\[dependencies.runtime]
        \\inspect = "^3.1.3"
    ;

    var manifest = try MoonstoneToml.parse(allocator, toml_text);
    defer manifest.deinit(allocator);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try manifest.serialize(allocator, &out.writer);
    try out.writer.flush();

    const serialized = out.writer.buffer[0..out.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, serialized, "[[dependencies]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "name = \"inspect\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "role = \"runtime\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "role = \"dependency\"") == null);
}

test "MoonstoneToml serializes dependencies by role then lexicographic name" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "ordered-dependencies"
        \\version = "0.1.0"
        \\kind = "script"
        \\
        \\[[dependencies]]
        \\name = "zeta-runtime"
        \\constraint = "^1.0.0"
        \\role = "runtime"
        \\
        \\[[dependencies]]
        \\name = "zeta-tool"
        \\constraint = "^1.0.0"
        \\role = "tool"
        \\
        \\[[dependencies]]
        \\name = "alpha-runtime"
        \\constraint = "^1.0.0"
        \\role = "runtime"
        \\
        \\[[dependencies]]
        \\name = "bravo-dev"
        \\constraint = "^1.0.0"
        \\role = "dev"
        \\
        \\[[dependencies]]
        \\name = "alpha-tool"
        \\constraint = "^1.0.0"
        \\role = "tool"
        \\
        \\[[dependencies]]
        \\name = "helper"
        \\constraint = "^1.0.0"
        \\role = "helper"
        \\
        \\[[dependencies]]
        \\name = "external"
        \\constraint = "^1.0.0"
        \\role = "external"
        \\
        \\[[dependencies]]
        \\name = "optional"
        \\constraint = "^1.0.0"
        \\role = "optional"
    ;

    var manifest = try MoonstoneToml.parse(allocator, toml_text);
    defer manifest.deinit(allocator);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try manifest.serialize(allocator, &out.writer);
    try out.writer.flush();

    const serialized = out.writer.buffer[0..out.writer.end];
    const expected_names = [_][]const u8{
        "alpha-tool",
        "zeta-tool",
        "bravo-dev",
        "alpha-runtime",
        "zeta-runtime",
        "helper",
        "external",
        "optional",
    };
    var previous_index: usize = 0;
    for (expected_names) |name| {
        const needle = try std.fmt.allocPrint(allocator, "name = \"{s}\"", .{name});
        defer allocator.free(needle);
        const index = std.mem.indexOfPos(u8, serialized, previous_index, needle) orelse return error.TestExpectedEqual;
        try std.testing.expect(index >= previous_index);
        previous_index = index + needle.len;
    }
}

test "MoonstoneToml round-trips build environment configuration" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "build-environment"
        \\version = "0.1.0"
        \\kind = "script"
        \\
        \\[build.env]
        \\OPENSSL_DIR = "/opt/homebrew/opt/openssl@3"
        \\CC = { from = "CC", optional = true, default = "zig cc" }
    ;

    var manifest = try MoonstoneToml.parse(allocator, toml_text);
    defer manifest.deinit(allocator);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try manifest.serialize(allocator, &out.writer);
    try out.writer.flush();

    var round_tripped = try MoonstoneToml.parse(allocator, out.writer.buffer[0..out.writer.end]);
    defer round_tripped.deinit(allocator);
    const build = round_tripped.build orelse return error.TestExpectedEqual;
    const openssl = build.env.get("OPENSSL_DIR") orelse return error.TestExpectedEqual;
    const cc = build.env.get("CC") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("/opt/homebrew/opt/openssl@3", openssl.value.?);
    try std.testing.expectEqualStrings("CC", cc.from.?);
    try std.testing.expect(cc.optional);
    try std.testing.expectEqualStrings("zig cc", cc.default.?);
}

test "MoonstoneToml round-trips declared origin" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "origin-project"
        \\version = "0.1.0"
        \\kind = "script"
        \\
        \\[origin]
        \\kind = "git"
        \\url = "https://github.com/moonstone-sh/origin-project"
        \\revision = "0123456789abcdef"
    ;

    var manifest = try MoonstoneToml.parse(allocator, toml_text);
    defer manifest.deinit(allocator);
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try manifest.serialize(allocator, &out.writer);
    try out.writer.flush();

    var round_tripped = try MoonstoneToml.parse(allocator, out.writer.buffer[0..out.writer.end]);
    defer round_tripped.deinit(allocator);
    const origin = round_tripped.origin orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("git", origin.kind);
    try std.testing.expectEqualStrings("https://github.com/moonstone-sh/origin-project", origin.url);
    try std.testing.expectEqualStrings("0123456789abcdef", origin.revision.?);
}

test "MoonstoneToml round-trips every root configuration section" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "complete-manifest"
        \\version = "1.2.3"
        \\kind = "bin"
        \\description = "round trip coverage"
        \\
        \\[interpreter]
        \\name = "lua"
        \\version = "5.4"
        \\abi = "5.4"
        \\
        \\manifest_version = 2
        \\
        \\[scripts]
        \\zeta.posix.sh = "lua zeta.lua"
        \\
        \\alpha.posix.sh = "lua alpha.lua"
        \\
        \\[[orbits.member]]
        \\name = "first"
        \\path = "examples/first"
        \\
        \\[[orbits.member]]
        \\name = "second"
        \\path = "examples/second"
        \\
        \\[build.env]
        \\OPENSSL_DIR = "/opt/openssl"
        \\CC = { from = "CC", optional = true, default = "zig cc" }
        \\
        \\[[registries]]
        \\name = "z-reg"
        \\resolver = "moonstone"
        \\url = "https://example.invalid/z"
        \\priority = 20
        \\
        \\[[registries]]
        \\name = "a-reg"
        \\resolver = "moonstone"
        \\path = "/tmp/a-reg"
        \\priority = 10
        \\
        \\[[dependencies]]
        \\name = "runtime-lib"
        \\constraint = "^1.0.0"
        \\registry = "rocks"
        \\role = "runtime"
        \\
        \\[[dependencies]]
        \\name = "tooling"
        \\constraint = "^2.0.0"
        \\role = "tool"
    ;

    var manifest = try MoonstoneToml.parse(allocator, toml_text);
    defer manifest.deinit(allocator);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try manifest.serialize(allocator, &out.writer);
    try out.writer.flush();

    const serialized = out.writer.buffer[0..out.writer.end];
    try std.testing.expect((std.mem.indexOf(u8, serialized, "name = \"zeta\"") orelse return error.TestExpectedEqual) <
        (std.mem.indexOf(u8, serialized, "name = \"alpha\"") orelse return error.TestExpectedEqual));
    try std.testing.expect((std.mem.indexOf(u8, serialized, "name = \"a-reg\"") orelse return error.TestExpectedEqual) <
        (std.mem.indexOf(u8, serialized, "name = \"z-reg\"") orelse return error.TestExpectedEqual));

    var round_tripped = try MoonstoneToml.parse(allocator, serialized);
    defer round_tripped.deinit(allocator);
    try std.testing.expectEqualStrings("complete-manifest", round_tripped.package.name);
    try std.testing.expectEqualStrings("round trip coverage", round_tripped.package.description.?);
    try std.testing.expectEqualStrings("lua alpha.lua", round_tripped.findScript("alpha").?.command);
    try std.testing.expectEqualStrings("lua zeta.lua", round_tripped.findScript("zeta").?.command);
    try std.testing.expectEqual(@as(usize, 2), round_tripped.orbits.items.len);
    try std.testing.expectEqualStrings("first", round_tripped.orbits.items[0].name);
    try std.testing.expectEqualStrings("examples/second", round_tripped.orbits.items[1].path);

    const build = round_tripped.build orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("/opt/openssl", build.env.get("OPENSSL_DIR").?.value.?);
    try std.testing.expectEqualStrings("zig cc", build.env.get("CC").?.default.?);

    const a_registry = round_tripped.registries.get("a-reg").?;
    const z_registry = round_tripped.registries.get("z-reg").?;
    try std.testing.expectEqualStrings("/tmp/a-reg", a_registry.path.?);
    try std.testing.expectEqualStrings("https://example.invalid/z", z_registry.url.?);
    try std.testing.expectEqual(@as(i32, 20), z_registry.priority);

    try std.testing.expectEqual(@as(usize, 2), round_tripped.dependencies.items.len);
    try std.testing.expectEqual(DependencyRole.tool, round_tripped.dependencies.items[0].role);
    try std.testing.expectEqual(DependencyRole.runtime, round_tripped.dependencies.items[1].role);
}

test "MoonstoneToml rejects legacy dependency role" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "legacy-role"
        \\version = "0.1.0"
        \\kind = "script"
        \\
        \\[[dependencies]]
        \\name = "inspect"
        \\constraint = "^3.1.3"
        \\role = "dependency"
    ;

    try std.testing.expectError(error.LegacyDependencyRole, MoonstoneToml.parse(allocator, toml_text));
}

test "MoonstoneToml rejects legacy dependency table role" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "legacy-role-table"
        \\version = "0.1.0"
        \\kind = "script"
        \\
        \\[dependencies.dependency]
        \\inspect = "^3.1.3"
    ;

    try std.testing.expectError(error.LegacyDependencyRole, MoonstoneToml.parse(allocator, toml_text));
}

test "MoonstoneToml canonicalizes external and peer roles" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "external-role"
        \\version = "0.1.0"
        \\kind = "script"
        \\
        \\[[dependencies]]
        \\name = "host-one"
        \\constraint = "*"
        \\role = "external"
        \\
        \\[[dependencies]]
        \\name = "host-two"
        \\constraint = "*"
        \\role = "peer"
    ;

    var manifest = try MoonstoneToml.parse(allocator, toml_text);
    defer manifest.deinit(allocator);
    try std.testing.expectEqual(DependencyRole.external, manifest.dependencies.items[0].role);
    try std.testing.expectEqual(DependencyRole.external, manifest.dependencies.items[1].role);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try manifest.serialize(allocator, &out.writer);
    try out.writer.flush();
    const serialized = out.writer.buffer[0..out.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, serialized, "role = \"external\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "role = \"peer\"") == null);
}

test "MoonstoneToml rejects legacy commands" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "legacy-commands"
        \\version = "0.1.0"
        \\kind = "script"
        \\
        \\[commands]
        \\export = "lua src/main.lua"
    ;

    try std.testing.expectError(error.LegacyScriptSyntax, MoonstoneToml.parse(allocator, toml_text));
}

test "MoonstoneToml parses structured script steps and argument forwarding" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\manifest_version = 2
        \\[package]
        \\name = "script-idl"
        \\version = "0.1.0"
        \\kind = "script"
        \\
        \\[scripts]
        \\build.posix.sh = "zig build \\\"$@\\\""
        \\
        \\build.windows.pwsh = "zig build @args"
        \\
        \\test.linux.bash = "zig build test"
    ;

    var manifest = try MoonstoneToml.parse(allocator, toml_text);
    defer manifest.deinit(allocator);

    const build = manifest.findScript("build").?;
    try std.testing.expectEqualStrings("zig build \"$@\"", build.command);
}

test "RemotePackageDescriptor parses table artifact runtime" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "moonstone/ballad"
        \\version = "0.2.12"
        \\kind = "bin"
        \\
        \\[[artifacts]]
        \\id = "bin-any"
        \\kind = "bin"
        \\target = "any"
        \\lua_api = "5.1"
        \\lua_abi = "any"
        \\runtime = { name = "moonstone/luajit", version = "2.1.0" }
        \\format = "tar.gz"
        \\url = "blobs/b3/00/00/fake.tar.gz"
        \\hash = "b3:fake"
        \\recipe_hash = "b3:recipe"
        \\bytes = 1
    ;

    var desc = try RemotePackageDescriptor.parse(allocator, toml_text);
    defer desc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), desc.artifact.len);
    try std.testing.expectEqualStrings("moonstone/luajit@2.1.0", desc.artifact[0].runtime);
}

test "RemotePackageDescriptor parses string artifact runtime" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "moonstone/ballad"
        \\version = "0.2.12"
        \\kind = "bin"
        \\
        \\[[artifacts]]
        \\id = "bin-any"
        \\kind = "bin"
        \\target = "any"
        \\lua_api = "5.1"
        \\lua_abi = "any"
        \\runtime = "moonstone/luajit@2.1.0"
        \\format = "tar.gz"
        \\url = "blobs/b3/00/00/fake.tar.gz"
        \\hash = "b3:fake"
        \\recipe_hash = "b3:recipe"
        \\bytes = 1
    ;

    var desc = try RemotePackageDescriptor.parse(allocator, toml_text);
    defer desc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), desc.artifact.len);
    try std.testing.expectEqualStrings("moonstone/luajit@2.1.0", desc.artifact[0].runtime);
}

test "RemotePackageDescriptor accepts canonical dependency registries" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "moonstone/ballad"
        \\version = "0.2.42"
        \\kind = "bin"
        \\
        \\[[dependencies]]
        \\name = "dkjson"
        \\constraint = "^2.9-1"
        \\registry = "rocks"
        \\role = "runtime"
    ;

    var desc = try RemotePackageDescriptor.parse(allocator, toml_text);
    defer desc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), desc.dependencies.len);
    try std.testing.expectEqualStrings("rocks", desc.dependencies[0].resolver.?);
}

test "RemotePackageDescriptor ignores malformed table pointer runtime string" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "moonstone/ballad"
        \\version = "0.2.12"
        \\kind = "bin"
        \\
        \\[[artifacts]]
        \\id = "bin-any"
        \\kind = "bin"
        \\target = "any"
        \\lua_api = "5.1"
        \\lua_abi = "any"
        \\runtime = "table: 0x01001bb928"
        \\format = "tar.gz"
        \\url = "blobs/b3/00/00/fake.tar.gz"
        \\hash = "b3:fake"
        \\recipe_hash = "b3:recipe"
        \\bytes = 1
    ;

    var desc = try RemotePackageDescriptor.parse(allocator, toml_text);
    defer desc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), desc.artifact.len);
    try std.testing.expectEqualStrings("", desc.artifact[0].runtime);
}

test "RemotePackageDescriptor parses artifact source provenance" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "moonstone/lua"
        \\version = "5.4.7"
        \\kind = "runtime"
        \\
        \\[[artifacts]]
        \\kind = "runtime"
        \\target = "aarch64-macos"
        \\lua_api = "lua54"
        \\lua_abi = "lua54"
        \\format = "tar.zst"
        \\url = "blobs/b3/runtime.tar.zst"
        \\hash = "b3:runtime"
        \\source_hash = "b3:source"
        \\source_url = "blobs/b3/lua-5.4.7.tar.gz"
        \\source_kind = "puc_lua_source"
        \\source_format = "tar.gz"
        \\recipe_hash = "b3:recipe"
        \\bytes = 1
    ;

    var desc = try RemotePackageDescriptor.parse(allocator, toml_text);
    defer desc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), desc.artifact.len);
    try std.testing.expectEqualStrings("b3:source", desc.artifact[0].source_hash);
    try std.testing.expectEqualStrings("blobs/b3/lua-5.4.7.tar.gz", desc.artifact[0].source_url);
    try std.testing.expectEqualStrings("puc_lua_source", desc.artifact[0].source_kind);
    try std.testing.expectEqualStrings("tar.gz", desc.artifact[0].source_format);
}

test "StoreManifest round-trip with dependencies" {
    const toml_text =
        \\
        \\[artifact]
        \\name = "parent"
        \\version = "1.0.0"
        \\kind = "lib"
        \\source_hash = "b3:abc"
        \\recipe_hash = "b3:def"
        \\artifact_hash = "b3:ghi"
        \\target = "native"
        \\
        \\[origin]
        \\resolver = "rocks"
        \\source = "https://luarocks.org/parent-1.0.0-1.src.rock"
        \\source_kind = "luarocks_src_rock"
        \\source_payload = "sources/parent-1.0.0-1.src.rock"
        \\rockspec = "https://luarocks.org/parent-1.0.0-1.rockspec"
        \\rockspec_hash = "b3:rockspec"
        \\rockspec_payload = "sources/parent-1.0.0-1.rockspec"
        \\
        \\[compat]
        \\runtime_version = "lua@5.4.7"
        \\lua_abi = "lua-5.4"
        \\runtime_artifact_hash = ""
        \\
        \\[[dependencies]]
        \\name = "child"
        \\constraint = ">=1.0.0"
        \\resolver = "rocks"
        \\role = "runtime"
    ;
    const sm = try StoreManifest.parse(std.heap.c_allocator, toml_text);
    // sm strings owned by parser arena; skip deinit to avoid allocator mismatch

    try std.testing.expectEqualStrings("parent", sm.artifact.name);
    try std.testing.expectEqualStrings("1.0.0", sm.artifact.version);
    try std.testing.expectEqualStrings("luarocks_src_rock", sm.origin.source_kind);
    try std.testing.expectEqualStrings("sources/parent-1.0.0-1.src.rock", sm.origin.source_payload);
    try std.testing.expectEqualStrings("sources/parent-1.0.0-1.rockspec", sm.origin.rockspec_payload);
    try std.testing.expectEqualStrings("lua@5.4.7", sm.compat.runtime_version);
    try std.testing.expectEqualStrings("lua-5.4", sm.compat.lua_abi);
    try std.testing.expectEqual(@as(usize, 1), sm.dependencies.len);
    try std.testing.expectEqualStrings("child", sm.dependencies[0].name);
    try std.testing.expectEqualStrings(">=1.0.0", sm.dependencies[0].constraint);
    try std.testing.expectEqualStrings("rocks", sm.dependencies[0].resolver.?);
    try std.testing.expectEqual(DependencyRole.runtime, sm.dependencies[0].role);
}

test "StoreManifest source provenance enrichment preserves artifact identity" {
    // Simulate the before-enrichment state: source_kind = "runtime" (fallback)
    const before =
        \\[artifact]
        \\name = "moonstone/lua"
        \\version = "5.4.7"
        \\kind = "runtime"
        \\source_hash = "b3:c93068e49db579e7b12639eed8bd5706aa84a997601ff776d8a4e7ef8d163077"
        \\recipe_hash = "b3:d1d80b54ca5882dc885d65536acd15bf98dd1709d9f91e29b2107af45ba5d6be"
        \\artifact_hash = "b3:c93068e49db579e7b12639eed8bd5706aa84a997601ff776d8a4e7ef8d163077"
        \\target = "aarch64-macos"
        \\
        \\[origin]
        \\resolver = "moonstone"
        \\source = "blobs/b3/c9/30/c93068e49db579e7b12639eed8bd5706aa84a997601ff776d8a4e7ef8d163077.tar.zst"
        \\source_kind = "runtime"
        \\source_payload = "sources/blob.tar.zst"
        \\
        \\[compat]
        \\runtime_version = "lua@unknown"
        \\lua_abi = "lua54"
        \\runtime_artifact_hash = ""
        \\
        \\[provides]
        \\runtime = [{ name = "lua", version = "5.4.7", abi = "lua54" }]
        \\bin = [{ name = "lua", path = "bin/lua" }, { name = "luac", path = "bin/luac" }]
    ;

    var sm_before = try StoreManifest.parse(std.testing.allocator, before);
    defer sm_before.deinit(std.testing.allocator);

    // Capture immutable identity fields before enrichment
    const artifact_hash_before = sm_before.artifact.artifact_hash;
    const recipe_hash_before = sm_before.artifact.recipe_hash;
    const target_before = sm_before.artifact.target;
    const name_before = sm_before.artifact.name;
    const version_before = sm_before.artifact.version;

    // Simulate enrichment: update provenance metadata only
    std.testing.allocator.free(sm_before.origin.source_kind);
    std.testing.allocator.free(sm_before.origin.source_payload);
    std.testing.allocator.free(sm_before.artifact.source_hash);

    sm_before.origin.source_kind = try std.testing.allocator.dupe(u8, "puc_lua_source");
    sm_before.origin.source_payload = try std.testing.allocator.dupe(u8, "sources/source.tar.gz");
    sm_before.origin.source_url = try std.testing.allocator.dupe(u8, "https://registry.moonstone.sh/registry/v0/blobs/b3/aa/bb/aabbccdd-source.tar.gz");
    sm_before.artifact.source_hash = try std.testing.allocator.dupe(u8, "b3:aabbccdd1234567890abcdef1234567890abcdef1234567890abcdef1234567890");

    // Serialize the enriched manifest
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try sm_before.serialize(std.testing.allocator, &aw.writer);
    try aw.writer.flush();
    const serialized = aw.writer.buffer[0..aw.writer.end];

    // Parse it back
    var sm_after = try StoreManifest.parse(std.testing.allocator, serialized);
    defer sm_after.deinit(std.testing.allocator);

    // Assert: provenance metadata was enriched
    try std.testing.expectEqualStrings("puc_lua_source", sm_after.origin.source_kind);
    try std.testing.expectEqualStrings("sources/source.tar.gz", sm_after.origin.source_payload);
    try std.testing.expectEqualStrings("https://registry.moonstone.sh/registry/v0/blobs/b3/aa/bb/aabbccdd-source.tar.gz", sm_after.origin.source_url);
    try std.testing.expectEqualStrings("b3:aabbccdd1234567890abcdef1234567890abcdef1234567890abcdef1234567890", sm_after.artifact.source_hash);

    // Assert: artifact identity is unchanged
    try std.testing.expectEqualStrings(artifact_hash_before, sm_after.artifact.artifact_hash);
    try std.testing.expectEqualStrings(recipe_hash_before, sm_after.artifact.recipe_hash);
    try std.testing.expectEqualStrings(target_before, sm_after.artifact.target);
    try std.testing.expectEqualStrings(name_before, sm_after.artifact.name);
    try std.testing.expectEqualStrings(version_before, sm_after.artifact.version);

    // Assert: source_payload is relative (not absolute)
    try std.testing.expect(!std.fs.path.isAbsolute(sm_after.origin.source_payload));
    try std.testing.expect(std.mem.startsWith(u8, sm_after.origin.source_payload, "sources/"));

    // Assert: serialized manifest contains no absolute paths in provenance fields
    // (source_url is a URL, not a filesystem path — that's allowed)
    try std.testing.expect(std.mem.indexOf(u8, serialized, "/Users/") == null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "/home/") == null);
}

test "StoreManifest source_url round-trips through serialize and parse" {
    const toml_with_url =
        \\[artifact]
        \\name = "moonstone/lua"
        \\version = "5.4.7"
        \\kind = "runtime"
        \\source_hash = "b3:sourcehash"
        \\recipe_hash = "b3:recipehash"
        \\artifact_hash = "b3:artifacthash"
        \\target = "aarch64-macos"
        \\
        \\[origin]
        \\resolver = "moonstone"
        \\source = "blobs/b3/ar/ti/facthash.tar.zst"
        \\source_kind = "puc_lua_source"
        \\source_payload = "sources/source.tar.gz"
        \\source_url = "https://registry.moonstone.sh/registry/v0/blobs/b3/so/ur/cehash.tar.gz"
        \\
        \\[compat]
        \\runtime_version = "lua@5.4.7"
        \\lua_abi = "lua54"
        \\runtime_artifact_hash = ""
        \\
        \\[provides]
        \\runtime = [{ name = "lua", version = "5.4.7", abi = "lua54" }]
    ;

    var sm = try StoreManifest.parse(std.testing.allocator, toml_with_url);
    defer sm.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("puc_lua_source", sm.origin.source_kind);
    try std.testing.expectEqualStrings("sources/source.tar.gz", sm.origin.source_payload);
    try std.testing.expectEqualStrings("https://registry.moonstone.sh/registry/v0/blobs/b3/so/ur/cehash.tar.gz", sm.origin.source_url);

    // Serialize and re-parse
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try sm.serialize(std.testing.allocator, &aw.writer);
    try aw.writer.flush();
    const serialized = aw.writer.buffer[0..aw.writer.end];

    var sm2 = try StoreManifest.parse(std.testing.allocator, serialized);
    defer sm2.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("puc_lua_source", sm2.origin.source_kind);
    try std.testing.expectEqualStrings("sources/source.tar.gz", sm2.origin.source_payload);
    try std.testing.expectEqualStrings("https://registry.moonstone.sh/registry/v0/blobs/b3/so/ur/cehash.tar.gz", sm2.origin.source_url);
}

test "StoreManifest native library linkage round-trips and defaults to unknown" {
    const prefix =
        "[artifact]\n" ++
        "name = \"native-probe\"\n" ++
        "version = \"1.0.0\"\n" ++
        "kind = \"lib\"\n" ++
        "artifact_hash = \"b3:artifact\"\n" ++
        "target = \"x86_64-linux-gnu\"\n" ++
        "lua_abi = \"lua54\"\n" ++
        "lua_api = \"5.4\"\n" ++
        "runtime = \"lua@5.4.7\"\n" ++
        "runtime_artifact_hash = \"b3:runtime\"\n" ++
        "resolver = \"rocks\"\n" ++
        "source = \"https://example.invalid/native-probe\"\n" ++
        "recipe_hash = \"b3:recipe\"\n\n" ++
        "[provides]\n";
    const explicit_linkage = prefix ++ "native_lib = [{ name = \"nativeprobe\", path = \"lib/native/libnativeprobe.so\", linkage = \"shared\" }]\n";

    var parsed = try StoreManifest.parse(std.testing.allocator, explicit_linkage);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(NativeLibraryLinkage.shared, parsed.provides.native_lib[0].linkage);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try parsed.serialize(std.testing.allocator, &output.writer);
    try output.writer.flush();
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffer[0..output.writer.end], "linkage = \"shared\"") != null);

    const legacy_linkage = prefix ++ "native_lib = [{ name = \"legacy\", path = \"lib/liblegacy.a\" }]\n";
    var legacy = try StoreManifest.parse(std.testing.allocator, legacy_linkage);
    defer legacy.deinit(std.testing.allocator);
    try std.testing.expectEqual(NativeLibraryLinkage.unknown, legacy.provides.native_lib[0].linkage);
}

test "MoonstoneToml rejects registry authentication fields" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "registry-auth"
        \\version = "0.1.0"
        \\kind = "script"
        \\
        \\[[registries]]
        \\name = "acme"
        \\resolver = "moonstone"
        \\url = "https://packages.example.test/registry/v0"
        \\credential_provider = "./acme.auth.lua"
    ;

    try std.testing.expectError(error.RegistryAuthenticationUnsupported, MoonstoneToml.parse(allocator, toml_text));
}

test "MoonstoneToml rejects dependency resolver fields" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "legacy-dependency-resolver"
        \\version = "0.1.0"
        \\kind = "script"
        \\
        \\[[dependencies]]
        \\name = "argparse"
        \\constraint = "^0.7.1-1"
        \\resolver = "rocks"
        \\role = "runtime"
    ;

    try std.testing.expectError(error.DependencyResolverSyntaxUnsupported, MoonstoneToml.parse(allocator, toml_text));
}

test "MoonstoneToml rejects reserved registry aliases" {
    const allocator = std.testing.allocator;
    const aliases = [_][]const u8{ "moonstone", "rocks", "default", "path", "link", "artifact" };
    for (aliases) |alias| {
        const toml_text = try std.fmt.allocPrint(allocator,
            \\[package]
            \\name = "reserved-registry"
            \\version = "0.1.0"
            \\kind = "script"
            \\
            \\[[registries]]
            \\name = "{s}"
            \\resolver = "moonstone"
            \\path = "./registry"
        , .{alias});
        defer allocator.free(toml_text);

        try std.testing.expectError(error.ReservedRegistryName, MoonstoneToml.parse(allocator, toml_text));
    }
}

test "RemotePackageDescriptor parses a transitive rocks dependency" {
    const allocator = std.testing.allocator;
    const toml_text =
        \\[package]
        \\name = "foreign-parent"
        \\version = "1.0.0"
        \\kind = "lib"
        \\
        \\[[dependencies]]
        \\name = "foreign-root"
        \\constraint = "== 1.0-1"
        \\registry = "rocks"
        \\role = "runtime"
        \\
        \\[[artifacts]]
        \\kind = "compiled"
        \\target = "any"
        \\lua_abi = "lua-5.4"
        \\runtime = "lua@5.4.7"
        \\url = "blobs/b3/example.tar.gz"
        \\hash = "b3:example"
        \\format = "tar.gz"
        \\
        \\[artifacts.materialize]
        \\type = "archive"
    ;

    var descriptor = try RemotePackageDescriptor.parse(allocator, toml_text);
    defer descriptor.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), descriptor.dependencies.len);
    try std.testing.expectEqualStrings("foreign-root", descriptor.dependencies[0].name);
    try std.testing.expectEqualStrings("rocks", descriptor.dependencies[0].resolver.?);
}
