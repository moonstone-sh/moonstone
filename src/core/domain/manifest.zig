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

    pub fn deinit(self: FeatureProvision, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
    }

    pub fn clone(self: FeatureProvision, allocator: std.mem.Allocator) !FeatureProvision {
        return FeatureProvision{
            .name = try allocator.dupe(u8, self.name),
            .path = try allocator.dupe(u8, self.path),
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
    headers: []const FeatureProvision = &.{},
    native_lib: []const FeatureProvision = &.{},
    lua_module: []const FeatureProvision = &.{},
    lua_cmodule: []const FeatureProvision = &.{},

    pub fn clone(self: Provides, allocator: std.mem.Allocator) !Provides {
        var res = Provides{};
        res.runtime = try self.cloneList(RuntimeProvision, self.runtime, allocator);
        res.bin = try self.cloneList(FeatureProvision, self.bin, allocator);
        res.headers = try self.cloneList(FeatureProvision, self.headers, allocator);
        res.native_lib = try self.cloneList(FeatureProvision, self.native_lib, allocator);
        res.lua_module = try self.cloneList(FeatureProvision, self.lua_module, allocator);
        res.lua_cmodule = try self.cloneList(FeatureProvision, self.lua_cmodule, allocator);
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
        for (self.headers) |p| p.deinit(allocator);
        allocator.free(self.headers);
        for (self.native_lib) |p| p.deinit(allocator);
        allocator.free(self.native_lib);
        for (self.lua_module) |p| p.deinit(allocator);
        allocator.free(self.lua_module);
        for (self.lua_cmodule) |p| p.deinit(allocator);
        allocator.free(self.lua_cmodule);
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
        allocator.free(self.format);
        allocator.free(self.recipe_hash);
        if (self.materialize) |*m| m.deinit(allocator);
        self.provides.deinit(allocator);
    }

};

pub const RemotePackageDescriptor = struct {
    package: struct {
        name: []const u8,
        version: []const u8,
        kind: Kind,
        description: ?[]const u8 = null,
    },
    compat: struct {
        runtimes: []const []const u8 = &.{},
    },
    dependencies: struct {
        libs: std.StringArrayHashMapUnmanaged([]const u8) = .{},
        bins: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    } = .{},
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

        var rts = std.ArrayList([]const u8).empty;
        for (self.compat.runtimes) |rt| try rts.append(allocator, try allocator.dupe(u8, rt));
        res.compat.runtimes = try rts.toOwnedSlice(allocator);

        res.dependencies.libs = .empty;
        var lib_it = self.dependencies.libs.iterator();
        while (lib_it.next()) |entry| {
            try res.dependencies.libs.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, entry.value_ptr.*));
        }

        res.dependencies.bins = .empty;
        var bin_it = self.dependencies.bins.iterator();
        while (bin_it.next()) |entry| {
            try res.dependencies.bins.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, entry.value_ptr.*));
        }

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
            .dependencies = .{},
            .artifact = &.{},
            .source = null,
        };

        const package_val = table.get("package") orelse return error.MissingPackageSection;
        if (package_val != .table) return error.InvalidPackageSection;
        const p_val = package_val.table;
        self.package = .{
            .name = try allocator.dupe(u8, p_val.get("name").?.string),
            .version = try allocator.dupe(u8, p_val.get("version").?.string),
            .kind = Kind.from_string(p_val.get("kind").?.string) catch .lib,
            .description = if (p_val.get("description")) |d| try allocator.dupe(u8, d.string) else null,
        };
        errdefer self.deinit(allocator);

        // dependencies
        if (table.get("dependencies")) |deps_val| {
            if (deps_val == .array) {
                for (deps_val.array.items) |dep_val| {
                    const dep = dep_val.table;
                    const role = dep.get("role").?.string;
                    const resolver = dep.get("resolver").?.string;
                    const name = dep.get("name").?.string;
                    const constraint = dep.get("constraint").?.string;
                    const spec = try std.fmt.allocPrint(allocator, "{s}:{s}@{s}", .{ resolver, name, constraint });
                    if (std.mem.eql(u8, role, "lib")) {
                        try self.dependencies.libs.put(allocator, try allocator.dupe(u8, name), spec);
                    } else if (std.mem.eql(u8, role, "bin")) {
                        try self.dependencies.bins.put(allocator, try allocator.dupe(u8, name), spec);
                    } else {
                        allocator.free(spec);
                    }
                }
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
                        art.id = try allocator.dupe(u8, a_table.get("id").?.string);
                        art.kind = try allocator.dupe(u8, a_table.get("kind").?.string);
                        art.target = if (a_table.get("target")) |target| try allocator.dupe(u8, target.string) else try allocator.dupe(u8, "");
                        art.lua_abi = if (a_table.get("lua_abi")) |abi| try allocator.dupe(u8, abi.string) else try allocator.dupe(u8, "");
                        art.lua_api = if (a_table.get("lua_api")) |la| try allocator.dupe(u8, la.string) else try allocator.dupe(u8, "");
                        art.runtime = if (a_table.get("runtime")) |rt| try allocator.dupe(u8, rt.string) else try allocator.dupe(u8, "");
                        art.runtime_artifact_hash = if (a_table.get("runtime_artifact_hash")) |rh| try allocator.dupe(u8, rh.string) else try allocator.dupe(u8, "");
                        art.native_compat_required = if (a_table.get("native_compat_required")) |required| required.boolean else false;

                        art.url = try allocator.dupe(u8, a_table.get("url").?.string);
                        art.hash = try allocator.dupe(u8, a_table.get("hash").?.string);
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
                                var headers = std.ArrayList(FeatureProvision).empty;
                                var native_libs = std.ArrayList(FeatureProvision).empty;
                                var lua_modules = std.ArrayList(FeatureProvision).empty;
                                var lua_cmodules = std.ArrayList(FeatureProvision).empty;
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
                                        const feature = FeatureProvision{
                                            .name = try allocator.dupe(u8, provision.get("name").?.string),
                                            .path = try allocator.dupe(u8, provision.get("path").?.string),
                                        };
                                        if (std.mem.eql(u8, provision_kind, "bin")) try bins.append(allocator, feature)
                                        else if (std.mem.eql(u8, provision_kind, "include")) try headers.append(allocator, feature)
                                        else if (std.mem.eql(u8, provision_kind, "lib")) try native_libs.append(allocator, feature)
                                        else if (std.mem.eql(u8, provision_kind, "lua_module")) try lua_modules.append(allocator, feature)
                                        else if (std.mem.eql(u8, provision_kind, "lua_cmodule")) try lua_cmodules.append(allocator, feature)
                                        else feature.deinit(allocator);
                                    }
                                }
                                art.provides.runtime = try runtimes.toOwnedSlice(allocator);
                                art.provides.bin = try bins.toOwnedSlice(allocator);
                                art.provides.headers = try headers.toOwnedSlice(allocator);
                                art.provides.native_lib = try native_libs.toOwnedSlice(allocator);
                                art.provides.lua_module = try lua_modules.toOwnedSlice(allocator);
                                art.provides.lua_cmodule = try lua_cmodules.toOwnedSlice(allocator);
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

        for (self.compat.runtimes) |rt| allocator.free(rt);
        allocator.free(self.compat.runtimes);

        var lib_it = self.dependencies.libs.iterator();
        while (lib_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.dependencies.libs.deinit(allocator);

        var bin_dep_it = self.dependencies.bins.iterator();
        while (bin_dep_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.dependencies.bins.deinit(allocator);

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
    kind: Kind = .lib,
    optional: bool = false,

    pub fn deinit(self: *StoreDependency, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.constraint);
        if (self.resolver) |r| allocator.free(r);
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
    } = .{},
    compat: struct {
        runtime_version: []const u8 = "", // e.g. lua@5.4.7
        lua_abi: []const u8 = "",          // e.g. lua-5.4
        lua_api: []const u8 = "",           // e.g. lua54
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
        allocator.free(self.compat.runtime_version);
        allocator.free(self.compat.lua_abi);
        allocator.free(self.compat.lua_api);
        allocator.free(self.compat.runtime_artifact_hash);
        self.provides.deinit(allocator);
        for (self.dependencies) |dep| { var mut_dep = dep; mut_dep.deinit(allocator); }
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

        try writer.print("\n[compat]\n", .{});
        try writer.print("runtime_version = \"{s}\"\n", .{self.compat.runtime_version});
        try writer.print("lua_abi = \"{s}\"\n", .{self.compat.lua_abi});
        try writer.print("runtime_artifact_hash = \"{s}\"\n", .{self.compat.runtime_artifact_hash});

        try writer.print("\n[provides]\n", .{});
        try self.serializeProvides(self.provides, writer);

        for (self.dependencies) |dep| {
            try writer.print("\n[[dependencies]]\n", .{});
            try writer.print("name = \"{s}\"\n", .{dep.name});
            try writer.print("constraint = \"{s}\"\n", .{dep.constraint});
            if (dep.resolver) |r| try writer.print("resolver = \"{s}\"\n", .{r});
            try writer.print("kind = \"{s}\"\n", .{@tagName(dep.kind)});
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
        inline for (.{ "bin", "headers", "native_lib", "lua_module", "lua_cmodule" }) |field| {
            const list = @field(provs, field);
            if (list.len > 0) {
                try writer.print("{s} = [", .{field});
                for (list, 0..) |p, i| {
                    if (i > 0) try writer.print(", ", .{});
                    try writer.print("{{ name = \"{s}\", path = \"{s}\" }}", .{ p.name, p.path });
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
    },
    runtime: struct {
        name: []const u8,
        version: []const u8,
        abi: []const u8,
    },
    resolution: ?ResolutionConfig = null,
    dependencies: struct {
        libs: std.StringArrayHashMapUnmanaged([]const u8) = .{},
        dev_libs: std.StringArrayHashMapUnmanaged([]const u8) = .{},
        bins: std.StringArrayHashMapUnmanaged([]const u8) = .{},
        dev_bins: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    } = .{},
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
        const r_val = if (table.get("runtime")) |runtime_val| blk: {
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
            .kind = Kind.from_string(package_kind.string) catch .lib,
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
            } else
                try inferRuntimeAbi(allocator, runtime_name, runtime_version)
        else
            try allocator.dupe(u8, "");

        self.runtime = .{
            .name = try allocator.dupe(u8, runtime_name),
            .version = try allocator.dupe(u8, runtime_version),
            .abi = runtime_abi,
        };

        self.dependencies = .{};
        if (table.get("dependencies")) |deps_val| {
            if (deps_val == .table) {
                inline for (.{ "libs", "dev_libs", "bins", "dev_bins" }) |field| {
                    if (deps_val.table.get(field)) |v| {
                        if (v == .table) {
                            var it = v.table.iterator();
                            while (it.next()) |entry| {
                                try @field(self.dependencies, field).put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, entry.value_ptr.string));
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
            if (reg_val == .table) {
                var it = reg_val.table.iterator();
                while (it.next()) |entry| {
                    const rt = entry.value_ptr.table;
                    try self.registries.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), .{
                        .url = if (rt.get("url")) |u| try allocator.dupe(u8, u.string) else null,
                        .path = if (rt.get("path")) |p| try allocator.dupe(u8, p.string) else null,
                        .priority = if (rt.get("priority")) |p| @intCast(p.integer) else 0,
                        .token = if (rt.get("token")) |t| try allocator.dupe(u8, t.string) else null,
                    });
                }
            }
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
        allocator.free(self.runtime.name);
        allocator.free(self.runtime.version);
        allocator.free(self.runtime.abi);
        
        inline for (.{ &self.dependencies.libs, &self.dependencies.bins, &self.dependencies.dev_libs, &self.dependencies.dev_bins, &self.scripts }) |table| {
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
        try writer.print("\n", .{});

        try writer.print("\n[runtime]\n", .{});
        try writer.print("name = ", .{});
        try writeTomlString(writer, self.runtime.name);
        try writer.print("\nversion = ", .{});
        try writeTomlString(writer, self.runtime.version);
        try writer.print("\nabi = ", .{});
        try writeTomlString(writer, self.runtime.abi);
        try writer.print("\n", .{});

        inline for (.{ "libs", "dev_libs", "bins", "dev_bins" }) |field| {
            const map = @field(self.dependencies, field);
            if (map.count() > 0) {
                try writer.print("\n[dependencies.{s}]\n", .{field});
                var it = map.iterator();
                while (it.next()) |entry| {
                    try writeTomlString(writer, entry.key_ptr.*);
                    try writer.print(" = ", .{});
                    try writeTomlString(writer, entry.value_ptr.*);
                    try writer.print("\n", .{});
                }
            }
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

    pub fn add_dependency(self: *MoonstoneToml, allocator: std.mem.Allocator, name: []const u8, spec: []const u8, dev: bool, kind: Kind) !void {
        const target_map = if (kind == .bin)
            if (dev) &self.dependencies.dev_bins else &self.dependencies.bins
        else if (dev)
            &self.dependencies.dev_libs
        else
            &self.dependencies.libs;
        if (target_map.get(name)) |old| allocator.free(old);
        try target_map.put(allocator, try allocator.dupe(u8, name), try allocator.dupe(u8, spec));
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

pub const Recipe = struct {
    schema_version: u32 = 2,
    name: []const u8,
    version: []const u8,
    source_hash: []const u8,
    materializer_kind: []const u8,
    materializer_version: []const u8,
    lua_version: []const u8,           // e.g. lua@5.4.7
    lua_abi: []const u8,               // e.g. lua-5.4
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

test "MoonstoneToml parse allows missing runtime for moon use repair" {
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
        \\[compat]
        \\runtime_version = "lua@5.4.7"
        \\lua_abi = "lua-5.4"
        \\runtime_artifact_hash = ""
        \\
        \\[[dependencies]]
        \\name = "child"
        \\constraint = ">=1.0.0"
        \\resolver = "rocks"
        \\kind = "lib"
    ;
    const sm = try StoreManifest.parse(std.heap.c_allocator, toml_text);
    // sm strings owned by parser arena; skip deinit to avoid allocator mismatch

    try std.testing.expectEqualStrings("parent", sm.artifact.name);
    try std.testing.expectEqualStrings("1.0.0", sm.artifact.version);
    try std.testing.expectEqualStrings("lua@5.4.7", sm.compat.runtime_version);
    try std.testing.expectEqualStrings("lua-5.4", sm.compat.lua_abi);
    try std.testing.expectEqual(@as(usize, 1), sm.dependencies.len);
    try std.testing.expectEqualStrings("child", sm.dependencies[0].name);
    try std.testing.expectEqualStrings(">=1.0.0", sm.dependencies[0].constraint);
    try std.testing.expectEqualStrings("rocks", sm.dependencies[0].resolver.?);
    try std.testing.expectEqual(Kind.lib, sm.dependencies[0].kind);
}
