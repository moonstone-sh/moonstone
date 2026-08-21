const std = @import("std");
const semver = @import("../domain/semver.zig");
const options_mod = @import("options.zig");
const luarocks = @import("sources/luarocks.zig");
const scheduler_mod = @import("../realization/scheduler.zig");

/// Bounded metadata preparation for LuaRocks requests known before PubGrub
/// starts. The solver remains the sole owner of dependency decisions; this
/// cache only overlaps independent network and rockspec parsing work.
pub const RocksMetadataPrefetch = struct {
    const allocator = std.heap.page_allocator;

    pub const Kind = enum {
        versions,
        dependencies,
    };

    pub const TaskState = enum {
        started,
        completed,
        failed,
    };

    pub const TaskEvent = struct {
        state: TaskState,
        kind: Kind,
        package_name: []const u8,
        version: ?[]const u8 = null,
        error_name: ?[]const u8 = null,
    };

    pub const TaskCallback = *const fn (context: ?*anyopaque, event: TaskEvent) void;

    const Result = union(enum) {
        pending,
        versions: []semver.Version,
        dependencies: luarocks.RockspecDependencies,
    };

    const Entry = struct {
        kind: Kind,
        package_name: []u8,
        registry_url: []u8,
        target: []u8,
        runtime: []u8,
        version: ?[]u8,
        result: Result = .pending,

        fn deinit(self: *Entry) void {
            allocator.free(self.package_name);
            allocator.free(self.registry_url);
            allocator.free(self.target);
            allocator.free(self.runtime);
            if (self.version) |value| allocator.free(value);
            switch (self.result) {
                .pending => {},
                .versions => |versions| {
                    for (versions) |item| item.deinit(allocator);
                    allocator.free(versions);
                },
                .dependencies => |dependencies| {
                    var mutable = dependencies;
                    mutable.deinit(allocator);
                },
            }
        }
    };

    io: std.Io,
    env: *std.process.Environ.Map,
    options: options_mod.ResolveOptions,
    lua_exe: ?[]const u8,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    on_task: ?TaskCallback = null,
    on_task_context: ?*anyopaque = null,
    cancellation_flag: ?*const std.atomic.Value(bool) = null,

    pub fn init(
        io: std.Io,
        env: *std.process.Environ.Map,
        options: options_mod.ResolveOptions,
        lua_exe: ?[]const u8,
    ) RocksMetadataPrefetch {
        return .{
            .io = io,
            .env = env,
            .options = options,
            .lua_exe = lua_exe,
        };
    }

    pub fn deinit(self: *RocksMetadataPrefetch) void {
        for (self.entries.items) |*entry| entry.deinit();
        self.entries.deinit(allocator);
    }

    pub fn setTaskCallback(self: *RocksMetadataPrefetch, callback: ?TaskCallback, context: ?*anyopaque) void {
        self.on_task = callback;
        self.on_task_context = context;
    }

    pub fn setCancellationFlag(self: *RocksMetadataPrefetch, flag: ?*const std.atomic.Value(bool)) void {
        self.cancellation_flag = flag;
        self.options.cancellation_flag = flag;
    }

    pub fn addVersions(
        self: *RocksMetadataPrefetch,
        package_name: []const u8,
        registry_url: []const u8,
        target: []const u8,
        runtime: []const u8,
    ) !void {
        try self.add(.versions, package_name, registry_url, target, runtime, null);
    }

    pub fn addDependencies(
        self: *RocksMetadataPrefetch,
        package_name: []const u8,
        version: []const u8,
        registry_url: []const u8,
        target: []const u8,
        runtime: []const u8,
    ) !void {
        try self.add(.dependencies, package_name, registry_url, target, runtime, version);
    }

    fn add(
        self: *RocksMetadataPrefetch,
        kind: Kind,
        package_name: []const u8,
        registry_url: []const u8,
        target: []const u8,
        runtime: []const u8,
        version: ?[]const u8,
    ) !void {
        if (self.findEntry(kind, package_name, registry_url, target, runtime, version) != null) return;

        try self.entries.append(allocator, .{
            .kind = kind,
            .package_name = try allocator.dupe(u8, package_name),
            .registry_url = try allocator.dupe(u8, registry_url),
            .target = try allocator.dupe(u8, target),
            .runtime = try allocator.dupe(u8, runtime),
            .version = if (version) |value| try allocator.dupe(u8, value) else null,
        });
    }

    pub fn execute(self: *RocksMetadataPrefetch, jobs: usize) !void {
        var scheduler = scheduler_mod.Scheduler{
            .allocator = allocator,
            .io = self.io,
            .task_count = self.entries.items.len,
            .context = @ptrCast(self),
            .run_task = runTask,
            .is_cancelled = isCancelled,
        };
        try scheduler.execute(jobs);
    }

    pub fn hasEntries(self: *const RocksMetadataPrefetch) bool {
        return self.entries.items.len > 0;
    }

    pub fn hasPendingEntries(self: *const RocksMetadataPrefetch) bool {
        for (self.entries.items) |entry| {
            if (entry.result == .pending) return true;
        }
        return false;
    }

    pub fn findVersions(
        self: *const RocksMetadataPrefetch,
        package_name: []const u8,
        registry_url: []const u8,
        target: []const u8,
        runtime: []const u8,
    ) ?[]const semver.Version {
        const entry = self.findEntry(.versions, package_name, registry_url, target, runtime, null) orelse return null;
        return switch (entry.result) {
            .versions => |versions| versions,
            else => null,
        };
    }

    pub fn findDependencies(
        self: *const RocksMetadataPrefetch,
        package_name: []const u8,
        version: []const u8,
        registry_url: []const u8,
        target: []const u8,
        runtime: []const u8,
    ) ?*const luarocks.RockspecDependencies {
        const entry = self.findEntry(.dependencies, package_name, registry_url, target, runtime, version) orelse return null;
        return switch (entry.result) {
            .dependencies => |*dependencies| dependencies,
            else => null,
        };
    }

    fn findEntry(
        self: *const RocksMetadataPrefetch,
        kind: Kind,
        package_name: []const u8,
        registry_url: []const u8,
        target: []const u8,
        runtime: []const u8,
        version: ?[]const u8,
    ) ?*const Entry {
        for (self.entries.items) |*entry| {
            if (entry.kind != kind) continue;
            if (!std.ascii.eqlIgnoreCase(entry.package_name, package_name)) continue;
            if (!std.mem.eql(u8, entry.registry_url, registry_url)) continue;
            if (!std.mem.eql(u8, entry.target, target)) continue;
            if (!std.mem.eql(u8, entry.runtime, runtime)) continue;
            if (!optionalStringsEqual(entry.version, version)) continue;
            return entry;
        }
        return null;
    }

    fn runTask(context: *anyopaque, task_index: usize) !void {
        const self: *RocksMetadataPrefetch = @ptrCast(@alignCast(context));
        if (self.isCancellationRequested()) return error.Cancelled;
        const entry = &self.entries.items[task_index];
        if (entry.result != .pending) return;
        self.emit(.{ .state = .started, .kind = entry.kind, .package_name = entry.package_name, .version = entry.version });

        var options = self.options;
        options.lua_exe = self.lua_exe;
        options.on_event = null;
        options.on_event_context = null;

        switch (entry.kind) {
            .versions => {
                entry.result = .{ .versions = luarocks.discoverVersions(
                    allocator,
                    self.io,
                    entry.package_name,
                    options,
                    self.env,
                    entry.registry_url,
                ) catch |err| switch (err) {
                    error.PackageNotFound, error.FileNotFound, error.RocksVersionDiscoveryFailed => try allocator.alloc(semver.Version, 0),
                    else => {
                        self.emit(.{ .state = .failed, .kind = entry.kind, .package_name = entry.package_name, .error_name = @errorName(err) });
                        return err;
                    },
                } };
            },
            .dependencies => {
                const version = entry.version orelse return error.MetadataVersionMissing;
                entry.result = .{ .dependencies = luarocks.query_dependencies(
                    allocator,
                    self.io,
                    entry.package_name,
                    version,
                    options,
                    self.env,
                    entry.registry_url,
                ) catch |err| switch (err) {
                    error.PackageNotFound, error.RockspecNotFound, error.FileNotFound => .{
                        .runtime = try allocator.alloc([]const u8, 0),
                        .build = try allocator.alloc([]const u8, 0),
                    },
                    else => {
                        self.emit(.{ .state = .failed, .kind = entry.kind, .package_name = entry.package_name, .version = version, .error_name = @errorName(err) });
                        return err;
                    },
                } };
            },
        }

        self.emit(.{ .state = .completed, .kind = entry.kind, .package_name = entry.package_name, .version = entry.version });
    }

    fn isCancelled(context: *anyopaque) bool {
        const self: *RocksMetadataPrefetch = @ptrCast(@alignCast(context));
        return self.isCancellationRequested();
    }

    fn isCancellationRequested(self: *const RocksMetadataPrefetch) bool {
        return if (self.cancellation_flag) |flag| flag.load(.acquire) else false;
    }

    fn emit(self: *const RocksMetadataPrefetch, event: TaskEvent) void {
        if (self.on_task) |callback| callback(self.on_task_context, event);
    }
};

fn optionalStringsEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

test "metadata prefetch deduplicates identical version requests" {
    var prefetch = RocksMetadataPrefetch.init(std.testing.io, undefined, .{}, "lua");
    defer prefetch.deinit();

    try prefetch.addVersions("dkjson", "https://luarocks.org", "x86_64-linux-gnu", "lua54");
    try prefetch.addVersions("DKJSON", "https://luarocks.org", "x86_64-linux-gnu", "lua54");
    try std.testing.expectEqual(@as(usize, 1), prefetch.entries.items.len);
}

test "metadata prefetch stops before claiming cancelled work" {
    var prefetch = RocksMetadataPrefetch.init(std.testing.io, undefined, .{}, "lua");
    defer prefetch.deinit();

    try prefetch.addVersions("dkjson", "https://luarocks.org", "x86_64-linux-gnu", "lua54");
    var cancelled = std.atomic.Value(bool).init(true);
    prefetch.setCancellationFlag(&cancelled);

    try std.testing.expectError(error.Cancelled, prefetch.execute(2));
}
