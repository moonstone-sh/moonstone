const std = @import("std");
pub const toml = @import("toml");

pub const Kind = enum {
    script,
    lib,
    bin,
    runtime,

    pub fn from_string(s: []const u8) !Kind {
        if (std.mem.eql(u8, s, "script")) return .script;
        if (std.mem.eql(u8, s, "lib")) return .lib;
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

pub const FeatureProvision = struct {
    name: []const u8,
    path: []const u8,
    entry_point: ?[]const u8 = null,
    module: ?[]const u8 = null,

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

    pub fn clone(self: CollectConfig, allocator: std.mem.Allocator) !CollectConfig {
        var res = CollectConfig{};
        res.lua_cmodules = try self.cloneList(FeatureProvision, self.lua_cmodules, allocator);
        res.lua_modules = try self.cloneList(FeatureProvision, self.lua_modules, allocator);
        res.bins = try self.cloneList(FeatureProvision, self.bins, allocator);
        res.headers = try self.cloneList(FeatureProvision, self.headers, allocator);
        res.native_lib = try self.cloneList(FeatureProvision, self.native_lib, allocator);
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
    cmake_args: []const []const u8 = &.{},

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
            .cmake_args = &.{},
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
        if (self.cmake_args.len > 0) {
            var clist = std.ArrayList([]const u8).empty;
            for (self.cmake_args) |c| try clist.append(allocator, try allocator.dupe(u8, c));
            res.cmake_args = try clist.toOwnedSlice(allocator);
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

        for (self.cmake_args) |ca| allocator.free(ca);
        allocator.free(self.cmake_args);
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
                    const resolver = if (dep.get("resolver")) |r| try allocator.dupe(u8, r.string) else null;
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
                        art.kind = try allocator.dupe(u8, a_table.get("kind").?.string);
                        art.target = if (a_table.get("target")) |target| try allocator.dupe(u8, target.string) else try allocator.dupe(u8, "");
                        art.lua_abi = if (a_table.get("lua_abi")) |abi| try allocator.dupe(u8, abi.string) else try allocator.dupe(u8, "");
                        art.lua_api = if (a_table.get("lua_api")) |la| try allocator.dupe(u8, la.string) else try allocator.dupe(u8, "");
                        art.runtime = if (a_table.get("runtime")) |rt| try parseArtifactRuntimeValue(allocator, rt) else try allocator.dupe(u8, "");
                        art.runtime_artifact_hash = if (a_table.get("interpreter_artifact_hash")) |rh| try allocator.dupe(u8, rh.string) else try allocator.dupe(u8, "");
                        art.native_compat_required = if (a_table.get("native_compat_required")) |required| required.boolean else false;

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
    role: DependencyRole = .runtime,
    optional: bool = false,

    pub fn deinit(self: *StoreDependency, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.constraint);
        if (self.resolver) |r| allocator.free(r);
    }

    /// Reconstruct a raw package-spec string suitable for parsePackageSpec.
    /// Handles both flat-array format (resolver + name + constraint) and
    /// sugar format (constraint may already contain resolver prefix).
    pub fn toSpecString(self: StoreDependency, allocator: std.mem.Allocator) ![]const u8 {
        if (self.resolver) |resolver| {
            if (self.constraint.len > 0 and std.mem.startsWith(u8, self.constraint, resolver) and self.constraint.len > resolver.len and self.constraint[resolver.len] == ':') {
                return try allocator.dupe(u8, self.constraint);
            }
            if (self.constraint.len > 0) {
                return try std.fmt.allocPrint(allocator, "{s}:{s}@{s}", .{ resolver, self.name, self.constraint });
            } else {
                return try std.fmt.allocPrint(allocator, "{s}:{s}", .{ resolver, self.name });
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
                    try writer.print(" }}", .{});
                }
                try writer.print("]\n", .{});
            }
        }
    }
};

pub const MoonstoneToml = struct {
    package: struct {
        name: []const u8,
        version: []const u8,
        kind: Kind,
        description: ?[]const u8 = null,
    },
    runtime: struct {
        name: []const u8,
        version: []const u8,
        abi: []const u8,
    },
    resolution: ?ResolutionConfig = null,
    dependencies: std.ArrayListUnmanaged(StoreDependency) = .empty,
    scripts: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    registries: std.StringArrayHashMapUnmanaged(RegistryConfig) = .{},

    pub fn init(allocator: std.mem.Allocator) MoonstoneToml {
        _ = allocator;
        return .{
            .package = undefined,
            .runtime = .{ .name = "", .version = "", .abi = "" },
        };
    }

    pub fn parse(allocator: std.mem.Allocator, content: []const u8) !MoonstoneToml {
        var parser = toml.Parser(toml.Table).init(allocator);
        defer parser.deinit();
        var res = try parser.parseString(content);
        defer res.deinit();
        const table = res.value;

        var self: MoonstoneToml = undefined;
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

        self.dependencies = .empty;
        if (table.get("dependencies")) |deps_val| {
            if (deps_val == .array) {
                for (deps_val.array.items) |dep_val| {
                    const dep = dep_val.table;
                    const role_str = if (dep.get("role")) |r| r.string else "runtime";
                    const role = try parseDependencyRole(role_str);
                    const resolver = if (dep.get("resolver")) |r| try allocator.dupe(u8, r.string) else null;
                    const name = try allocator.dupe(u8, dep.get("name").?.string);
                    const constraint = if (dep.get("constraint")) |c| try allocator.dupe(u8, c.string) else try allocator.dupe(u8, "");
                    const optional = if (dep.get("optional")) |o| o.boolean else false;
                    try self.dependencies.append(allocator, .{
                        .name = name,
                        .constraint = constraint,
                        .resolver = resolver,
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

        self.scripts = .{};
        if (table.get("scripts") orelse table.get("commands")) |s_val| {
            if (s_val == .table) {
                var it = s_val.table.iterator();
                while (it.next()) |entry| {
                    try self.scripts.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, entry.value_ptr.string));
                }
            }
        }

        self.registries = .{};
        if (table.get("registries")) |reg_val| {
            try extractRegistriesFromToml(allocator, reg_val, &self.registries);
        }

        self.resolution = null;
        if (table.get("resolution")) |res_val| {
            if (res_val == .table) {
                if (res_val.table.get("default_order")) |o_val| {
                    if (o_val == .array) {
                        var list = std.ArrayList([]const u8).empty;
                        for (o_val.array.items) |o| try list.append(allocator, try allocator.dupe(u8, o.string));
                        self.resolution = .{ .default_order = try list.toOwnedSlice(allocator) };
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
        allocator.free(self.runtime.name);
        allocator.free(self.runtime.version);
        allocator.free(self.runtime.abi);

        for (self.dependencies.items) |dep| {
            var mut_dep = dep;
            mut_dep.deinit(allocator);
        }
        self.dependencies.deinit(allocator);

        inline for (.{&self.scripts}) |table| {
            var it = table.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            table.deinit(allocator);
        }

        var reg_it = self.registries.iterator();
        while (reg_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.registries.deinit(allocator);

        if (self.resolution) |res| {
            for (res.default_order) |o| allocator.free(o);
            allocator.free(res.default_order);
        }
    }

    /// Serializes to TOML.
    /// NOTE: Manual serialization is used here because the 'toml' library struggles with
    /// std.StringArrayHashMapUnmanaged and nested arena-allocated structures.
    /// FUTURE: This could be refactored to use DTOs (Data Transfer Objects) that match
    /// the library's expected structure more closely if automated serialization is desired.
    pub fn serialize(self: MoonstoneToml, allocator: std.mem.Allocator, writer: anytype) !void {
        _ = allocator;
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
        try writer.print("\n", .{});

        try writer.print("\n[interpreter]\n", .{});
        try writer.print("name = ", .{});
        try writeTomlString(writer, self.runtime.name);
        try writer.print("\nversion = ", .{});
        try writeTomlString(writer, self.runtime.version);
        try writer.print("\nabi = ", .{});
        try writeTomlString(writer, self.runtime.abi);
        try writer.print("\n", .{});

        // All dependencies are written as [[dependencies]] entries.
        // This is the canonical format — no more [dependencies.<role>] table
        // sections.  The parser still reads the old table format for backward
        // compatibility, but the serializer always writes the array format.
        for (self.dependencies.items) |dep| {
            try writer.print("\n[[dependencies]]\n", .{});
            try writer.print("name = ", .{});
            try writeTomlString(writer, dep.name);
            try writer.print("\nconstraint = ", .{});
            try writeTomlString(writer, dep.constraint);
            if (dep.resolver) |r| {
                try writer.print("\nresolver = ", .{});
                try writeTomlString(writer, r);
            }
            try writer.print("\nrole = \"{s}\"\n", .{dep.role.toString()});
            if (dep.optional) try writer.print("optional = true\n", .{});
        }

        if (self.scripts.count() > 0) {
            try writer.print("\n[scripts]\n", .{});
            var it = self.scripts.iterator();
            while (it.next()) |entry| {
                try writeTomlString(writer, entry.key_ptr.*);
                try writer.print(" = ", .{});
                try writeTomlString(writer, entry.value_ptr.*);
                try writer.print("\n", .{});
            }
        }

        if (self.registries.count() > 0) {
            var it = self.registries.iterator();
            while (it.next()) |entry| {
                try writer.print("\n[registries.\"{s}\"]\n", .{entry.key_ptr.*});
                if (entry.value_ptr.url) |u| try writer.print("url = \"{s}\"\n", .{u});
                if (entry.value_ptr.path) |p| try writer.print("path = \"{s}\"\n", .{p});
                try writer.print("priority = {d}\n", .{entry.value_ptr.priority});
                if (entry.value_ptr.token) |t| try writer.print("token = \"{s}\"\n", .{t});
            }
        }

        if (self.resolution) |res| {
            try writer.print("\n[resolution]\n", .{});
            try writer.print("default_order = [", .{});
            for (res.default_order, 0..) |o, i| {
                if (i > 0) try writer.print(", ", .{});
                try writer.print("\"{s}\"", .{o});
            }
            try writer.print("]\n", .{});
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

    pub fn add_dependency(self: *MoonstoneToml, allocator: std.mem.Allocator, name: []const u8, spec: []const u8, role: DependencyRole, optional: bool) !void {
        try self.add_dependency_with_resolver(allocator, name, spec, role, optional, null);
    }

    pub fn add_dependency_with_resolver(self: *MoonstoneToml, allocator: std.mem.Allocator, name: []const u8, spec: []const u8, role: DependencyRole, optional: bool, resolver: ?[]const u8) !void {
        // Check if it already exists, replace it
        for (self.dependencies.items) |*dep| {
            if (std.mem.eql(u8, dep.name, name)) {
                allocator.free(dep.constraint);
                dep.constraint = try allocator.dupe(u8, spec);
                if (dep.resolver) |r| allocator.free(r);
                dep.resolver = if (resolver) |r| try allocator.dupe(u8, r) else null;
                dep.role = role;
                dep.optional = optional;
                return;
            }
        }

        try self.dependencies.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .constraint = try allocator.dupe(u8, spec),
            .resolver = if (resolver) |r| try allocator.dupe(u8, r) else null,
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

pub const ResolutionConfig = struct {
    default_order: []const []const u8 = &.{ "moonstone", "rocks" },
};

pub const RegistryConfig = struct {
    url: ?[]const u8 = null,
    path: ?[]const u8 = null,
    priority: i32 = 0,
    token: ?[]const u8 = null,

    pub fn deinit(self: RegistryConfig, allocator: std.mem.Allocator) void {
        if (self.url) |u| allocator.free(u);
        if (self.path) |p| allocator.free(p);
        if (self.token) |t| allocator.free(t);
    }
};

/// Extract registries from a raw TOML value supporting both syntaxes:
///   [registries."name"] or [registries.name]  (table of tables)
///   [[registries]] with `name` field            (array of tables)
///
/// Populates `out_map` with registry name -> RegistryConfig.
pub fn extractRegistriesFromToml(
    allocator: std.mem.Allocator,
    registries_value: toml.Value,
    out_map: *std.StringArrayHashMapUnmanaged(RegistryConfig),
) !void {
    switch (registries_value) {
        .table => |tab| {
            // Dotted-table syntax: [registries."name"] or [registries.name]
            var it = tab.iterator();
            while (it.next()) |entry| {
                const reg_name = entry.key_ptr.*;
                if (std.mem.eql(u8, reg_name, "moonstone") or std.mem.eql(u8, reg_name, "rocks")) continue;
                if (entry.value_ptr.* != .table) continue;
                const rt = entry.value_ptr.table;
                try out_map.put(allocator, try allocator.dupe(u8, reg_name), .{
                    .url = if (rt.get("url")) |u| try allocator.dupe(u8, u.string) else null,
                    .path = if (rt.get("path")) |p| try allocator.dupe(u8, p.string) else null,
                    .priority = if (rt.get("priority")) |p| @intCast(p.integer) else 0,
                    .token = if (rt.get("token")) |t| try allocator.dupe(u8, t.string) else null,
                });
            }
        },
        .array => |ar| {
            // Array-table syntax: [[registries]]
            for (ar.items) |item| {
                if (item != .table) continue;
                const rt = item.table;
                const name_v = rt.get("name") orelse continue;
                const reg_name = name_v.string;
                if (std.mem.eql(u8, reg_name, "moonstone") or std.mem.eql(u8, reg_name, "rocks")) continue;
                try out_map.put(allocator, try allocator.dupe(u8, reg_name), .{
                    .url = if (rt.get("url")) |u| try allocator.dupe(u8, u.string) else null,
                    .path = if (rt.get("path")) |p| try allocator.dupe(u8, p.string) else null,
                    .priority = if (rt.get("priority")) |p| @intCast(p.integer) else 0,
                    .token = if (rt.get("token")) |t| try allocator.dupe(u8, t.string) else null,
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

test "MoonstoneToml parse migrates legacy commands to scripts" {
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

    var manifest = try MoonstoneToml.parse(allocator, toml_text);
    defer manifest.deinit(allocator);

    try std.testing.expectEqualStrings("lua src/main.lua", manifest.scripts.get("export").?);
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
    sm_before.origin.source_url = try std.testing.allocator.dupe(u8, "https://moonstone.sh/registry/v0/blobs/b3/aa/bb/aabbccdd-source.tar.gz");
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
    try std.testing.expectEqualStrings("https://moonstone.sh/registry/v0/blobs/b3/aa/bb/aabbccdd-source.tar.gz", sm_after.origin.source_url);
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
        \\source_url = "https://moonstone.sh/registry/v0/blobs/b3/so/ur/cehash.tar.gz"
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
    try std.testing.expectEqualStrings("https://moonstone.sh/registry/v0/blobs/b3/so/ur/cehash.tar.gz", sm.origin.source_url);

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
    try std.testing.expectEqualStrings("https://moonstone.sh/registry/v0/blobs/b3/so/ur/cehash.tar.gz", sm2.origin.source_url);
}
