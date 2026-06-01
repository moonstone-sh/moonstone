const std = @import("std");
const manifest = @import("../domain/manifest.zig");
const driver_mod = @import("driver.zig");

const c = driver_mod.c;

pub const RuntimeProvision = struct {
    artifact_hash: []const u8,
    name: []const u8,
    version: []const u8,
    abi: []const u8,

    pub fn deinit(self: *RuntimeProvision, allocator: std.mem.Allocator) void {
        allocator.free(self.artifact_hash);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.abi);
    }
};

pub const ArtifactCandidate = struct {
    artifact_hash: []const u8,
    name: []const u8,
    version: []const u8,
    kind: manifest.Kind,
    target: []const u8,
    lua_abi: ?[]const u8 = null,
    runtime: ?[]const u8 = null,
    path: []const u8,
    manifest_path: []const u8,

    pub fn deinit(self: *ArtifactCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.artifact_hash);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.target);

        if (self.lua_abi) |a| allocator.free(a);
        if (self.runtime) |r| allocator.free(r);

        allocator.free(self.path);
        allocator.free(self.manifest_path);
    }
};

pub const ArtifactProvision = struct {
    name: []const u8,
    path: []const u8,

    pub fn deinit(self: *ArtifactProvision, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

pub const ArtifactProvisions = struct {
    bins: []const ArtifactProvision,
    headers: []const ArtifactProvision,
    libs: []const ArtifactProvision,
    lua_modules: []const ArtifactProvision,
    lua_cmodules: []const ArtifactProvision,

    pub fn deinit(self: *ArtifactProvisions, allocator: std.mem.Allocator) void {
        for (self.bins) |*item| item.deinit(allocator);
        for (self.headers) |*item| item.deinit(allocator);
        for (self.libs) |*item| item.deinit(allocator);
        for (self.lua_modules) |*item| item.deinit(allocator);
        for (self.lua_cmodules) |*item| item.deinit(allocator);

        allocator.free(self.bins);
        allocator.free(self.headers);
        allocator.free(self.libs);
        allocator.free(self.lua_modules);
        allocator.free(self.lua_cmodules);
    }
};

pub const ArtifactStore = struct {
    driver: *driver_mod.StoreDriver,

    pub fn init(driver: *driver_mod.StoreDriver) @This() {
        return .{ .driver = driver };
    }

    fn allocator(self: @This()) std.mem.Allocator {
        return self.driver.allocator;
    }

    fn db(self: @This()) !*c.sqlite3 {
        return try self.driver.getDb();
    }

    pub fn clearArtifacts(self: @This()) !void {
        try self.driver.begin();
        errdefer self.driver.rollback() catch {};

        const tables = [_][:0]const u8{
            "DELETE FROM provides_runtime;",
            "DELETE FROM provides_bin;",
            "DELETE FROM provides_headers;",
            "DELETE FROM provides_native_lib;",
            "DELETE FROM provides_lua_module;",
            "DELETE FROM provides_lua_cmodule;",
            "DELETE FROM artifacts;",
        };

        for (tables) |sql| {
            try self.driver.execRaw(sql);
        }

        try self.driver.commit();
    }

    pub fn registerArtifact(
        self: @This(),
        sm: manifest.StoreManifest,
        path: []const u8,
        manifest_path: []const u8,
    ) !void {
        try self.driver.begin();
        errdefer self.driver.rollback() catch {};

        try self.insertArtifact(sm, path, manifest_path);

        try self.replaceProvisions("provides_runtime", sm.artifact.artifact_hash);
        for (sm.provides.runtime) |r| {
            try self.driver.exec(
                "INSERT INTO provides_runtime (artifact_hash, name, version, abi) VALUES (?, ?, ?, ?);",
                .{ sm.artifact.artifact_hash, r.name, r.version, r.abi },
            );
        }

        try self.replaceProvisions("provides_bin", sm.artifact.artifact_hash);
        for (sm.provides.bin) |b| {
            try self.driver.exec(
                "INSERT INTO provides_bin (artifact_hash, name, path) VALUES (?, ?, ?);",
                .{ sm.artifact.artifact_hash, b.name, b.path },
            );
        }

        try self.replaceProvisions("provides_headers", sm.artifact.artifact_hash);
        for (sm.provides.headers) |h| {
            try self.driver.exec(
                "INSERT INTO provides_headers (artifact_hash, name, path) VALUES (?, ?, ?);",
                .{ sm.artifact.artifact_hash, h.name, h.path },
            );
        }

        try self.replaceProvisions("provides_native_lib", sm.artifact.artifact_hash);
        for (sm.provides.native_lib) |l| {
            try self.driver.exec(
                "INSERT INTO provides_native_lib (artifact_hash, name, path) VALUES (?, ?, ?);",
                .{ sm.artifact.artifact_hash, l.name, l.path },
            );
        }

        try self.replaceProvisions("provides_lua_module", sm.artifact.artifact_hash);
        for (sm.provides.lua_module) |l| {
            try self.driver.exec(
                "INSERT INTO provides_lua_module (artifact_hash, name, path) VALUES (?, ?, ?);",
                .{ sm.artifact.artifact_hash, l.name, l.path },
            );
        }

        try self.replaceProvisions("provides_lua_cmodule", sm.artifact.artifact_hash);
        for (sm.provides.lua_cmodule) |l| {
            try self.driver.exec(
                "INSERT INTO provides_lua_cmodule (artifact_hash, name, path) VALUES (?, ?, ?);",
                .{ sm.artifact.artifact_hash, l.name, l.path },
            );
        }

        try self.driver.commit();
    }

    fn insertArtifact(
        self: @This(),
        sm: manifest.StoreManifest,
        path: []const u8,
        manifest_path: []const u8,
    ) !void {
        try self.driver.exec(
            \\INSERT OR REPLACE INTO artifacts
            \\  (artifact_hash, name, version, kind, target, lua_abi, runtime, path, manifest_path)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        ,
            .{
                sm.artifact.artifact_hash,
                sm.artifact.name,
                sm.artifact.version,
                @tagName(sm.artifact.kind),
                sm.artifact.target,
                sm.compat.lua_abi,
                sm.compat.runtime,
                path,
                manifest_path,
            },
        );
    }

    fn replaceProvisions(self: @This(), comptime table: []const u8, artifact_hash: []const u8) !void {
        const sql = comptime "DELETE FROM " ++ table ++ " WHERE artifact_hash = ?;";
        try self.driver.exec(sql, .{artifact_hash});
    }

    pub fn hasArtifact(self: @This(), artifact_hash: []const u8) !bool {
        const sql = "SELECT 1 FROM artifacts WHERE artifact_hash = ? LIMIT 1;";

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(try self.db(), sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SQLitePrepareError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const transient = driver_mod.moonstone_sqlite_transient_ptr;
        _ = c.sqlite3_bind_text(stmt, 1, artifact_hash.ptr, @intCast(artifact_hash.len), transient);

        return c.sqlite3_step(stmt) == c.SQLITE_ROW;
    }

    pub fn deleteArtifact(self: @This(), artifact_hash: []const u8) !void {
        try self.driver.begin();
        errdefer self.driver.rollback() catch {};

        // Because the schema uses ON DELETE CASCADE, deleting the artifact row
        // removes all provides_* rows. These explicit deletes are still okay,
        // but not necessary if foreign_keys=ON.
        try self.driver.exec("DELETE FROM artifacts WHERE artifact_hash = ?;", .{artifact_hash});

        try self.driver.commit();
    }

    pub fn getArtifactPath(self: @This(), artifact_hash: []const u8) !?[]const u8 {
        const sql = "SELECT path FROM artifacts WHERE artifact_hash = ? LIMIT 1;";

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(try self.db(), sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SQLitePrepareError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const transient = driver_mod.moonstone_sqlite_transient_ptr;
        _ = c.sqlite3_bind_text(stmt, 1, artifact_hash.ptr, @intCast(artifact_hash.len), transient);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            return try self.allocator().dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)));
        }

        return null;
    }

    pub fn getCandidateByHash(self: @This(), artifact_hash: []const u8) !?ArtifactCandidate {
        const sql =
            \\SELECT artifact_hash, name, version, kind, target, lua_abi, runtime, path, manifest_path
            \\FROM artifacts
            \\WHERE artifact_hash = ?
            \\LIMIT 1;
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(try self.db(), sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SQLitePrepareError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const transient = driver_mod.moonstone_sqlite_transient_ptr;
        _ = c.sqlite3_bind_text(stmt, 1, artifact_hash.ptr, @intCast(artifact_hash.len), transient);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            return try self.readArtifactCandidate(stmt);
        }

        return null;
    }

    pub fn findCandidatesByName(self: @This(), pkg_name: []const u8) ![]const ArtifactCandidate {
        var candidates = std.ArrayList(ArtifactCandidate).empty;

        const sql =
            \\SELECT artifact_hash, name, version, kind, target, lua_abi, runtime, path, manifest_path
            \\FROM artifacts
            \\WHERE name = ?
            \\ORDER BY version DESC;
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(try self.db(), sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SQLitePrepareError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const transient = driver_mod.moonstone_sqlite_transient_ptr;
        _ = c.sqlite3_bind_text(stmt, 1, pkg_name.ptr, @intCast(pkg_name.len), transient);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try candidates.append(self.allocator(), try self.readArtifactCandidate(stmt));
        }

        return candidates.toOwnedSlice(self.allocator());
    }

    fn readArtifactCandidate(self: @This(), stmt: ?*c.sqlite3_stmt) !ArtifactCandidate {
        return .{
            .artifact_hash = try self.allocator().dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
            .name = try self.allocator().dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
            .version = try self.allocator().dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2))),
            .kind = try manifest.Kind.from_string(std.mem.span(c.sqlite3_column_text(stmt, 3))),
            .target = try self.allocator().dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 4))),
            .lua_abi = if (c.sqlite3_column_text(stmt, 5)) |a|
                try self.allocator().dupe(u8, std.mem.span(a))
            else
                null,
            .runtime = if (c.sqlite3_column_text(stmt, 6)) |r|
                try self.allocator().dupe(u8, std.mem.span(r))
            else
                null,
            .path = try self.allocator().dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 7))),
            .manifest_path = try self.allocator().dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 8))),
        };
    }

    pub fn getRuntimeProvision(self: @This(), artifact_hash: []const u8) !?RuntimeProvision {
        const sql =
            \\SELECT artifact_hash, name, version, abi
            \\FROM provides_runtime
            \\WHERE artifact_hash = ?
            \\LIMIT 1;
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(try self.db(), sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SQLitePrepareError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const transient = driver_mod.moonstone_sqlite_transient_ptr;
        _ = c.sqlite3_bind_text(stmt, 1, artifact_hash.ptr, @intCast(artifact_hash.len), transient);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            return RuntimeProvision{
                .artifact_hash = try self.allocator().dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
                .name = try self.allocator().dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
                .version = try self.allocator().dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2))),
                .abi = try self.allocator().dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3))),
            };
        }

        return null;
    }

    pub fn getProvisions(self: @This(), artifact_hash: []const u8) !ArtifactProvisions {
        return .{
            .bins = try self.loadSimpleProvisions("provides_bin", artifact_hash),
            .headers = try self.loadSimpleProvisions("provides_headers", artifact_hash),
            .libs = try self.loadSimpleProvisions("provides_native_lib", artifact_hash),
            .lua_modules = try self.loadSimpleProvisions("provides_lua_module", artifact_hash),
            .lua_cmodules = try self.loadSimpleProvisions("provides_lua_cmodule", artifact_hash),
        };
    }

    fn loadSimpleProvisions(
        self: @This(),
        comptime table: []const u8,
        artifact_hash: []const u8,
    ) ![]const ArtifactProvision {
        var list = std.ArrayList(ArtifactProvision).empty;

        const sql = comptime "SELECT name, path FROM " ++ table ++ " WHERE artifact_hash = ?;";

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(try self.db(), sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SQLitePrepareError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const transient = driver_mod.moonstone_sqlite_transient_ptr;
        _ = c.sqlite3_bind_text(stmt, 1, artifact_hash.ptr, @intCast(artifact_hash.len), transient);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(self.allocator(), .{
                .name = try self.allocator().dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
                .path = try self.allocator().dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
            });
        }

        return list.toOwnedSlice(self.allocator());
    }
};
