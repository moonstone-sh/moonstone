const std = @import("std");
const manifest = @import("../domain/manifest.zig");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub extern const moonstone_sqlite_transient_ptr: c.sqlite3_destructor_type;

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

        self.* = undefined;
    }
};

pub const Candidate = struct {
    name: []const u8,
    version: []const u8,
    kind: manifest.Kind,
    artifact_hash: []const u8,
    lua_abi: ?[]const u8 = null,
    lua_api: ?[]const u8 = null,
    runtime: ?[]const u8 = null,
    runtime_artifact_hash: ?[]const u8 = null,
    resolver: ?[]const u8 = null,
    source: ?[]const u8 = null,
    path: []const u8,

    pub fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.artifact_hash);
        if (self.lua_abi) |a| allocator.free(a);
        if (self.lua_api) |a| allocator.free(a);
        if (self.runtime) |r| allocator.free(r);
        if (self.runtime_artifact_hash) |h| allocator.free(h);
        if (self.resolver) |r| allocator.free(r);
        if (self.source) |s| allocator.free(s);
        allocator.free(self.path);

        self.* = undefined;
    }
};

pub const ArtifactQuery = struct {
    name: []const u8,
    resolver: ?[]const u8 = null,
    version: ?[]const u8 = null,
    kind: ?manifest.Kind = null,
    target: ?[]const u8 = null,
    runtime: ?[]const u8 = null,
    lua_abi: ?[]const u8 = null,
    lua_api: ?[]const u8 = null,
    runtime_artifact_hash: ?[]const u8 = null,
    native_compat_required: ?bool = null,
};

pub const ArtifactProvision = struct {
    name: []const u8,
    path: []const u8,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);

        self.* = undefined;
    }
};

pub const LinkEntry = struct {
    name: []const u8,
    path: []const u8,
    version: []const u8,
    kind: []const u8,
    mode: []const u8,
    registered_at: []const u8,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.version);
        allocator.free(self.kind);
        allocator.free(self.mode);
        allocator.free(self.registered_at);

        self.* = undefined;
    }
};

pub const StoreDriver = struct {
    db: ?*c.sqlite3,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db_path: [:0]const u8) !StoreDriver {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(db_path, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |handle| _ = c.sqlite3_close(handle);
            return sqliteError(rc);
        }

        var self = StoreDriver{
            .db = db,
            .allocator = allocator,
        };

        try self.init_schema();
        try self.migrate_schema();
        try self.exec("PRAGMA journal_mode=WAL;", .{});
        try self.exec("PRAGMA synchronous=NORMAL;", .{});
        try self.exec("PRAGMA busy_timeout=5000;", .{});

        return self;
    }

    fn migrate_schema(self: StoreDriver) !void {
        _ = self.exec("ALTER TABLE provides_bin ADD COLUMN entry_point TEXT;", .{}) catch {};
        _ = self.exec("ALTER TABLE artifacts ADD COLUMN description TEXT;", .{}) catch {};
    }

    pub fn deinit(self: *StoreDriver) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
            self.db = null;
        }
    }

    pub fn getDb(self: StoreDriver) !*c.sqlite3 {
        return self.db orelse error.SQLiteNotInitialized;
    }

    pub fn begin(self: StoreDriver) !void {
        try self.exec("BEGIN TRANSACTION;", .{});
    }

    pub fn rollback(self: StoreDriver) !void {
        try self.exec("ROLLBACK;", .{});
    }

    pub fn commit(self: StoreDriver) !void {
        try self.exec("COMMIT;", .{});
    }

    pub fn clear_all_data(self: StoreDriver) !void {
        const tables = [_][]const u8{ "provides_runtime", "provides_bin", "provides_headers", "provides_native_lib", "provides_lua_module", "provides_lua_cmodule", "artifacts" };
        for (tables) |table| {
            const sql = try std.fmt.allocPrint(self.allocator, "DELETE FROM {s};", .{table});
            defer self.allocator.free(sql);
            const sql_z = try self.allocator.dupeZ(u8, sql);
            defer self.allocator.free(sql_z);
            const rc = c.sqlite3_exec(self.db, sql_z, null, null, null);
            if (rc != c.SQLITE_OK) return sqliteError(rc);
        }
    }

    fn init_schema(self: StoreDriver) !void {
        const schema =
            \\CREATE TABLE IF NOT EXISTS artifacts (
            \\  artifact_hash TEXT PRIMARY KEY,
            \\  name TEXT NOT NULL,
            \\  version TEXT NOT NULL,
            \\  kind TEXT NOT NULL,
            \\  target TEXT NOT NULL,
            \\  lua_abi TEXT,
            \\  runtime TEXT,
            \\  path TEXT NOT NULL,
            \\  manifest_path TEXT NOT NULL,
            \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\);
            \\CREATE TABLE IF NOT EXISTS provides_runtime (
            \\  artifact_hash TEXT NOT NULL,
            \\  name TEXT NOT NULL,
            \\  version TEXT NOT NULL,
            \\  abi TEXT NOT NULL,
            \\  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
            \\);
            \\CREATE TABLE IF NOT EXISTS provides_bin (
            \\  artifact_hash TEXT NOT NULL,
            \\  name TEXT NOT NULL,
            \\  path TEXT NOT NULL,
            \\  entry_point TEXT,
            \\  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
            \\);
            \\CREATE TABLE IF NOT EXISTS provides_bin_lua (
            \\  artifact_hash TEXT NOT NULL,
            \\  name TEXT NOT NULL,
            \\  path TEXT NOT NULL,
            \\  entry_point TEXT,
            \\  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
            \\);
            \\CREATE TABLE IF NOT EXISTS provides_headers (
            \\  artifact_hash TEXT NOT NULL,
            \\  name TEXT NOT NULL,
            \\  path TEXT NOT NULL,
            \\  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
            \\);
            \\CREATE TABLE IF NOT EXISTS provides_native_lib (
            \\  artifact_hash TEXT NOT NULL,
            \\  name TEXT NOT NULL,
            \\  path TEXT NOT NULL,
            \\  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
            \\);
            \\CREATE TABLE IF NOT EXISTS provides_lua_module (
            \\  artifact_hash TEXT NOT NULL,
            \\  name TEXT NOT NULL,
            \\  path TEXT NOT NULL,
            \\  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
            \\);
            \\CREATE TABLE IF NOT EXISTS provides_lua_cmodule (
            \\  artifact_hash TEXT NOT NULL,
            \\  name TEXT NOT NULL,
            \\  path TEXT NOT NULL,
            \\  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
            \\);
            \\CREATE TABLE IF NOT EXISTS provides_script (
            \\  artifact_hash TEXT NOT NULL,
            \\  name TEXT NOT NULL,
            \\  path TEXT NOT NULL,
            \\  entry_point TEXT,
            \\  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
            \\);
            \\CREATE TABLE IF NOT EXISTS provides_asset (
            \\  artifact_hash TEXT NOT NULL,
            \\  name TEXT NOT NULL,
            \\  path TEXT NOT NULL,
            \\  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
            \\);
            \\CREATE TABLE IF NOT EXISTS provides_ballad_plugin (
            \\  artifact_hash TEXT NOT NULL,
            \\  name TEXT NOT NULL,
            \\  path TEXT NOT NULL,
            \\  entry_point TEXT,
            \\  module TEXT,
            \\  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
            \\);
            \\CREATE TABLE IF NOT EXISTS links (
            \\  name TEXT PRIMARY KEY,
            \\  path TEXT NOT NULL,
            \\  version TEXT NOT NULL,
            \\  kind TEXT NOT NULL,
            \\  mode TEXT NOT NULL,
            \\  registered_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\);
        ;
        const rc = c.sqlite3_exec(self.db, schema, null, null, null);
        if (rc != c.SQLITE_OK) return sqliteError(rc);
        // Migration: add new columns if they don't exist (ignored if already present)
        _ = c.sqlite3_exec(self.db, "ALTER TABLE artifacts ADD COLUMN lua_api TEXT;", null, null, null);
        _ = c.sqlite3_exec(self.db, "ALTER TABLE artifacts ADD COLUMN runtime_artifact_hash TEXT;", null, null, null);
        _ = c.sqlite3_exec(self.db, "ALTER TABLE artifacts ADD COLUMN resolver TEXT;", null, null, null);
        _ = c.sqlite3_exec(self.db, "ALTER TABLE artifacts ADD COLUMN source TEXT;", null, null, null);
        _ = c.sqlite3_exec(self.db, "ALTER TABLE artifacts ADD COLUMN native_compat_required INTEGER DEFAULT 0;", null, null, null);
    }

    fn sqliteError(rc: c_int) anyerror {
        return switch (rc) {
            c.SQLITE_CANTOPEN => error.SQLiteCantOpen,
            c.SQLITE_READONLY => error.SQLiteReadOnly,
            c.SQLITE_CORRUPT, c.SQLITE_NOTADB => error.SQLiteCorrupt,
            c.SQLITE_BUSY, c.SQLITE_LOCKED => error.SQLiteBusy,
            else => error.SQLiteExecError,
        };
    }

    pub fn register_link(self: StoreDriver, entry: LinkEntry) !void {
        const sql =
            \\INSERT OR REPLACE INTO links (name, path, version, kind, mode)
            \\VALUES (?, ?, ?, ?, ?);
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SQLitePrepareError;
        defer _ = c.sqlite3_finalize(stmt);

        const transient = moonstone_sqlite_transient_ptr;

        _ = c.sqlite3_bind_text(stmt, 1, entry.name.ptr, @intCast(entry.name.len), transient);
        _ = c.sqlite3_bind_text(stmt, 2, entry.path.ptr, @intCast(entry.path.len), transient);
        _ = c.sqlite3_bind_text(stmt, 3, entry.version.ptr, @intCast(entry.version.len), transient);
        _ = c.sqlite3_bind_text(stmt, 4, entry.kind.ptr, @intCast(entry.kind.len), transient);
        _ = c.sqlite3_bind_text(stmt, 5, entry.mode.ptr, @intCast(entry.mode.len), transient);

        const step_res = c.sqlite3_step(stmt);
        if (step_res != c.SQLITE_DONE and step_res != c.SQLITE_ROW) return error.SQLiteStepError;
    }

    pub fn unregister_link(self: StoreDriver, name: []const u8) !void {
        const sql = "DELETE FROM links WHERE name = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SQLitePrepareError;
        defer _ = c.sqlite3_finalize(stmt);

        const transient = moonstone_sqlite_transient_ptr;
        _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), transient);

        const step_res = c.sqlite3_step(stmt);
        if (step_res != c.SQLITE_DONE and step_res != c.SQLITE_ROW) return error.SQLiteStepError;
    }

    pub fn get_link(self: StoreDriver, name: []const u8) !?LinkEntry {
        const sql = "SELECT name, path, version, kind, mode, registered_at FROM links WHERE name = ? LIMIT 1;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SQLitePrepareError;
        defer _ = c.sqlite3_finalize(stmt);

        const transient = moonstone_sqlite_transient_ptr;
        _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), transient);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            return LinkEntry{
                .name = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
                .path = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
                .version = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2))),
                .kind = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3))),
                .mode = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 4))),
                .registered_at = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 5))),
            };
        }
        return null;
    }

    pub fn list_links(self: StoreDriver) ![]const LinkEntry {
        var list = std.ArrayList(LinkEntry).empty;
        const sql = "SELECT name, path, version, kind, mode, registered_at FROM links ORDER BY name ASC;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SQLitePrepareError;
        defer _ = c.sqlite3_finalize(stmt);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
                .path = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
                .version = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2))),
                .kind = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3))),
                .mode = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 4))),
                .registered_at = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 5))),
            });
        }
        return list.toOwnedSlice(self.allocator);
    }

    pub fn register_artifact(self: StoreDriver, allocator: std.mem.Allocator, sm: manifest.StoreManifest, path: []const u8, manifest_path: []const u8) !void {
        _ = allocator;
        const sql =
            \\INSERT OR REPLACE INTO artifacts
            \\  (artifact_hash, name, version, kind, target, lua_abi, runtime, path, manifest_path, lua_api, runtime_artifact_hash, resolver, source, native_compat_required)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SQLitePrepareError;
        defer _ = c.sqlite3_finalize(stmt);

        const transient = moonstone_sqlite_transient_ptr;

        _ = c.sqlite3_bind_text(stmt, 1, sm.artifact.artifact_hash.ptr, @intCast(sm.artifact.artifact_hash.len), transient);
        _ = c.sqlite3_bind_text(stmt, 2, sm.artifact.name.ptr, @intCast(sm.artifact.name.len), transient);
        _ = c.sqlite3_bind_text(stmt, 3, sm.artifact.version.ptr, @intCast(sm.artifact.version.len), transient);
        _ = c.sqlite3_bind_text(stmt, 4, @tagName(sm.artifact.kind).ptr, @intCast(@tagName(sm.artifact.kind).len), transient);
        _ = c.sqlite3_bind_text(stmt, 5, sm.artifact.target.ptr, @intCast(sm.artifact.target.len), transient);
        _ = c.sqlite3_bind_text(stmt, 6, sm.compat.lua_abi.ptr, @intCast(sm.compat.lua_abi.len), transient);
        _ = c.sqlite3_bind_text(stmt, 7, sm.compat.runtime_version.ptr, @intCast(sm.compat.runtime_version.len), transient);

        _ = c.sqlite3_bind_text(stmt, 8, path.ptr, @intCast(path.len), transient);
        _ = c.sqlite3_bind_text(stmt, 9, manifest_path.ptr, @intCast(manifest_path.len), transient);
        _ = c.sqlite3_bind_text(stmt, 10, sm.compat.lua_api.ptr, @intCast(sm.compat.lua_api.len), transient);
        _ = c.sqlite3_bind_text(stmt, 11, sm.compat.runtime_artifact_hash.ptr, @intCast(sm.compat.runtime_artifact_hash.len), transient);
        _ = c.sqlite3_bind_text(stmt, 12, sm.origin.resolver.ptr, @intCast(sm.origin.resolver.len), transient);
        _ = c.sqlite3_bind_text(stmt, 13, sm.origin.source.ptr, @intCast(sm.origin.source.len), transient);
        _ = c.sqlite3_bind_int(stmt, 14, if (sm.compat.runtime_artifact_hash.len > 0) 1 else 0);

        const step_res = c.sqlite3_step(stmt);
        if (step_res != c.SQLITE_DONE and step_res != c.SQLITE_ROW) return error.SQLiteStepError;

        try self.exec("DELETE FROM provides_runtime WHERE artifact_hash = ?;", .{sm.artifact.artifact_hash});
        for (sm.provides.runtime) |r| {
            try self.exec("INSERT INTO provides_runtime (artifact_hash, name, version, abi) VALUES (?, ?, ?, ?);", .{ sm.artifact.artifact_hash, r.name, r.version, r.abi });
        }
        try self.exec("DELETE FROM provides_bin WHERE artifact_hash = ?;", .{sm.artifact.artifact_hash});
        for (sm.provides.bin) |b| {
            try self.exec("INSERT INTO provides_bin (artifact_hash, name, path, entry_point) VALUES (?, ?, ?, ?);", .{ sm.artifact.artifact_hash, b.name, b.path, b.entry_point });
        }
        try self.exec("DELETE FROM provides_bin_lua WHERE artifact_hash = ?;", .{sm.artifact.artifact_hash});
        for (sm.provides.bin_lua) |b| {
            try self.exec("INSERT INTO provides_bin_lua (artifact_hash, name, path, entry_point) VALUES (?, ?, ?, ?);", .{ sm.artifact.artifact_hash, b.name, b.path, b.entry_point });
        }
        try self.exec("DELETE FROM provides_headers WHERE artifact_hash = ?;", .{sm.artifact.artifact_hash});
        for (sm.provides.headers) |h| {
            try self.exec("INSERT INTO provides_headers (artifact_hash, name, path) VALUES (?, ?, ?);", .{ sm.artifact.artifact_hash, h.name, h.path });
        }
        try self.exec("DELETE FROM provides_native_lib WHERE artifact_hash = ?;", .{sm.artifact.artifact_hash});
        for (sm.provides.native_lib) |l| {
            try self.exec("INSERT INTO provides_native_lib (artifact_hash, name, path) VALUES (?, ?, ?);", .{ sm.artifact.artifact_hash, l.name, l.path });
        }
        try self.exec("DELETE FROM provides_lua_module WHERE artifact_hash = ?;", .{sm.artifact.artifact_hash});
        for (sm.provides.lua_module) |l| {
            try self.exec("INSERT INTO provides_lua_module (artifact_hash, name, path) VALUES (?, ?, ?);", .{ sm.artifact.artifact_hash, l.name, l.path });
        }
        try self.exec("DELETE FROM provides_lua_cmodule WHERE artifact_hash = ?;", .{sm.artifact.artifact_hash});
        for (sm.provides.lua_cmodule) |l| {
            try self.exec("INSERT INTO provides_lua_cmodule (artifact_hash, name, path) VALUES (?, ?, ?);", .{ sm.artifact.artifact_hash, l.name, l.path });
        }
        try self.exec("DELETE FROM provides_script WHERE artifact_hash = ?;", .{sm.artifact.artifact_hash});
        for (sm.provides.script) |s| {
            try self.exec("INSERT INTO provides_script (artifact_hash, name, path, entry_point) VALUES (?, ?, ?, ?);", .{ sm.artifact.artifact_hash, s.name, s.path, s.entry_point });
        }
        try self.exec("DELETE FROM provides_asset WHERE artifact_hash = ?;", .{sm.artifact.artifact_hash});
        for (sm.provides.asset) |a| {
            try self.exec("INSERT INTO provides_asset (artifact_hash, name, path) VALUES (?, ?, ?);", .{ sm.artifact.artifact_hash, a.name, a.path });
        }
        try self.exec("DELETE FROM provides_ballad_plugin WHERE artifact_hash = ?;", .{sm.artifact.artifact_hash});
        for (sm.provides.ballad_plugin) |b| {
            try self.exec("INSERT INTO provides_ballad_plugin (artifact_hash, name, path, entry_point, module) VALUES (?, ?, ?, ?, ?);", .{ sm.artifact.artifact_hash, b.name, b.path, b.entry_point, b.module });
        }
    }

    pub fn exec(self: StoreDriver, comptime sql: [:0]const u8, args: anytype) !void {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SQLitePrepareError;
        defer _ = c.sqlite3_finalize(stmt);

        const transient = moonstone_sqlite_transient_ptr;

        inline for (std.meta.fields(@TypeOf(args)), 0..) |f, i| {
            const val = @field(args, f.name);
            const idx = @as(c_int, @intCast(i + 1));
            switch (@typeInfo(@TypeOf(val))) {
                .pointer => |p| {
                    if (p.size == .slice and p.child == u8) {
                        _ = c.sqlite3_bind_text(stmt, idx, val.ptr, @intCast(val.len), transient);
                    }
                },
                .optional => |opt| {
                    if (opt.child == []const u8) {
                        if (val) |v| {
                            _ = c.sqlite3_bind_text(stmt, idx, v.ptr, @intCast(v.len), transient);
                        } else {
                            _ = c.sqlite3_bind_null(stmt, idx);
                        }
                    }
                },
                else => {},
            }
        }

        const step_res = c.sqlite3_step(stmt);
        if (step_res != c.SQLITE_DONE and step_res != c.SQLITE_ROW) return error.SQLiteStepError;
    }

    pub fn get_provision_runtime(self: StoreDriver, artifact_hash: []const u8) !?RuntimeProvision {
        const sql = "SELECT artifact_hash, name, version, abi FROM provides_runtime WHERE artifact_hash = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SQLitePrepareError;
        defer _ = c.sqlite3_finalize(stmt);

        const transient = moonstone_sqlite_transient_ptr;
        _ = c.sqlite3_bind_text(stmt, 1, artifact_hash.ptr, @intCast(artifact_hash.len), transient);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            return RuntimeProvision{
                .artifact_hash = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
                .name = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
                .version = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2))),
                .abi = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3))),
            };
        }
        return null;
    }

    pub fn get_provisions(self: StoreDriver, artifact_hash: []const u8) !struct {
        bins: []const manifest.FeatureProvision,
        bin_luas: []const manifest.FeatureProvision,
        headers: []const manifest.FeatureProvision,
        libs: []const manifest.FeatureProvision,
        lua_modules: []const manifest.FeatureProvision,
        lua_cmodules: []const manifest.FeatureProvision,
        scripts: []const manifest.FeatureProvision,
        assets: []const manifest.FeatureProvision,
        ballad_plugins: []const manifest.FeatureProvision,
    } {
        var bins = std.ArrayList(manifest.FeatureProvision).empty;
        var bin_luas = std.ArrayList(manifest.FeatureProvision).empty;
        var headers = std.ArrayList(manifest.FeatureProvision).empty;
        var libs = std.ArrayList(manifest.FeatureProvision).empty;
        var lua_modules = std.ArrayList(manifest.FeatureProvision).empty;
        var lua_cmodules = std.ArrayList(manifest.FeatureProvision).empty;
        var scripts = std.ArrayList(manifest.FeatureProvision).empty;
        var assets = std.ArrayList(manifest.FeatureProvision).empty;
        var ballad_plugins = std.ArrayList(manifest.FeatureProvision).empty;

        const transient = moonstone_sqlite_transient_ptr;

        // Bins
        {
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT name, path, entry_point FROM provides_bin WHERE artifact_hash = ?;", -1, &stmt, null) == c.SQLITE_OK) {
                defer _ = c.sqlite3_finalize(stmt);
                _ = c.sqlite3_bind_text(stmt, 1, artifact_hash.ptr, @intCast(artifact_hash.len), transient);
                while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                    try bins.append(self.allocator, .{
                        .name = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
                        .path = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
                        .entry_point = if (c.sqlite3_column_text(stmt, 2)) |ep| try self.allocator.dupe(u8, std.mem.span(ep)) else null,
                    });
                }
            }
        }
        // Bin Luas
        {
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT name, path, entry_point FROM provides_bin_lua WHERE artifact_hash = ?;", -1, &stmt, null) == c.SQLITE_OK) {
                defer _ = c.sqlite3_finalize(stmt);
                _ = c.sqlite3_bind_text(stmt, 1, artifact_hash.ptr, @intCast(artifact_hash.len), transient);
                while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                    try bin_luas.append(self.allocator, .{
                        .name = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
                        .path = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
                        .entry_point = if (c.sqlite3_column_text(stmt, 2)) |ep| try self.allocator.dupe(u8, std.mem.span(ep)) else null,
                    });
                }
            }
        }
        // Headers
        {
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT name, path FROM provides_headers WHERE artifact_hash = ?;", -1, &stmt, null) == c.SQLITE_OK) {
                defer _ = c.sqlite3_finalize(stmt);
                _ = c.sqlite3_bind_text(stmt, 1, artifact_hash.ptr, @intCast(artifact_hash.len), transient);
                while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                    try headers.append(self.allocator, .{
                        .name = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
                        .path = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
                    });
                }
            }
        }
        // Libs
        {
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT name, path FROM provides_native_lib WHERE artifact_hash = ?;", -1, &stmt, null) == c.SQLITE_OK) {
                defer _ = c.sqlite3_finalize(stmt);
                _ = c.sqlite3_bind_text(stmt, 1, artifact_hash.ptr, @intCast(artifact_hash.len), transient);
                while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                    try libs.append(self.allocator, .{
                        .name = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
                        .path = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
                    });
                }
            }
        }
        // Lua Modules
        {
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT name, path FROM provides_lua_module WHERE artifact_hash = ?;", -1, &stmt, null) == c.SQLITE_OK) {
                defer _ = c.sqlite3_finalize(stmt);
                _ = c.sqlite3_bind_text(stmt, 1, artifact_hash.ptr, @intCast(artifact_hash.len), transient);
                while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                    try lua_modules.append(self.allocator, .{
                        .name = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
                        .path = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
                    });
                }
            }
        }
        // Lua CModules
        {
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT name, path FROM provides_lua_cmodule WHERE artifact_hash = ?;", -1, &stmt, null) == c.SQLITE_OK) {
                defer _ = c.sqlite3_finalize(stmt);
                _ = c.sqlite3_bind_text(stmt, 1, artifact_hash.ptr, @intCast(artifact_hash.len), transient);
                while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                    try lua_cmodules.append(self.allocator, .{
                        .name = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
                        .path = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
                    });
                }
            }
        }

        // Scripts
        {
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT name, path, entry_point FROM provides_script WHERE artifact_hash = ?;", -1, &stmt, null) == c.SQLITE_OK) {
                defer _ = c.sqlite3_finalize(stmt);
                _ = c.sqlite3_bind_text(stmt, 1, artifact_hash.ptr, @intCast(artifact_hash.len), transient);
                while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                    try scripts.append(self.allocator, .{
                        .name = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
                        .path = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
                        .entry_point = if (c.sqlite3_column_text(stmt, 2)) |ep| try self.allocator.dupe(u8, std.mem.span(ep)) else null,
                    });
                }
            }
        }
        // Assets
        {
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT name, path FROM provides_asset WHERE artifact_hash = ?;", -1, &stmt, null) == c.SQLITE_OK) {
                defer _ = c.sqlite3_finalize(stmt);
                _ = c.sqlite3_bind_text(stmt, 1, artifact_hash.ptr, @intCast(artifact_hash.len), transient);
                while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                    try assets.append(self.allocator, .{
                        .name = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
                        .path = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
                    });
                }
            }
        }
        // Ballad Plugins
        {
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT name, path, entry_point, module FROM provides_ballad_plugin WHERE artifact_hash = ?;", -1, &stmt, null) == c.SQLITE_OK) {
                defer _ = c.sqlite3_finalize(stmt);
                _ = c.sqlite3_bind_text(stmt, 1, artifact_hash.ptr, @intCast(artifact_hash.len), transient);
                while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                    try ballad_plugins.append(self.allocator, .{
                        .name = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
                        .path = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
                        .entry_point = if (c.sqlite3_column_text(stmt, 2)) |ep| try self.allocator.dupe(u8, std.mem.span(ep)) else null,
                        .module = if (c.sqlite3_column_text(stmt, 3)) |m| try self.allocator.dupe(u8, std.mem.span(m)) else null,
                    });
                }
            }
        }
        return .{
            .bins = try bins.toOwnedSlice(self.allocator),
            .bin_luas = try bin_luas.toOwnedSlice(self.allocator),
            .headers = try headers.toOwnedSlice(self.allocator),
            .libs = try libs.toOwnedSlice(self.allocator),
            .lua_modules = try lua_modules.toOwnedSlice(self.allocator),
            .lua_cmodules = try lua_cmodules.toOwnedSlice(self.allocator),
            .scripts = try scripts.toOwnedSlice(self.allocator),
            .assets = try assets.toOwnedSlice(self.allocator),
            .ballad_plugins = try ballad_plugins.toOwnedSlice(self.allocator),
        };
    }

    pub fn has_artifact(self: StoreDriver, artifact_hash: []const u8) !bool {
        const sql = "SELECT 1 FROM artifacts WHERE artifact_hash = ? LIMIT 1;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SQLitePrepareError;
        defer _ = c.sqlite3_finalize(stmt);

        const transient = moonstone_sqlite_transient_ptr;
        _ = c.sqlite3_bind_text(stmt, 1, artifact_hash.ptr, @intCast(artifact_hash.len), transient);

        return c.sqlite3_step(stmt) == c.SQLITE_ROW;
    }

    pub fn delete_artifact(self: StoreDriver, artifact_hash: []const u8) !void {
        const transient = moonstone_sqlite_transient_ptr;

        const sql_bin = "DELETE FROM provides_bin WHERE artifact_hash = ?;";
        const sql_bin_lua = "DELETE FROM provides_bin_lua WHERE artifact_hash = ?;";
        const sql_headers = "DELETE FROM provides_headers WHERE artifact_hash = ?;";
        const sql_native = "DELETE FROM provides_native_lib WHERE artifact_hash = ?;";
        const sql_lua_module = "DELETE FROM provides_lua_module WHERE artifact_hash = ?;";
        const sql_lua_cmodule = "DELETE FROM provides_lua_cmodule WHERE artifact_hash = ?;";
        const sql_script = "DELETE FROM provides_script WHERE artifact_hash = ?;";
        const sql_asset = "DELETE FROM provides_asset WHERE artifact_hash = ?;";
        const sql_ballad_plugin = "DELETE FROM provides_ballad_plugin WHERE artifact_hash = ?;";
        const sql_runtime = "DELETE FROM provides_runtime WHERE artifact_hash = ?;";
        const sql_artifacts = "DELETE FROM artifacts WHERE artifact_hash = ?;";

        inline for (&.{ sql_bin, sql_bin_lua, sql_headers, sql_native, sql_lua_module, sql_lua_cmodule, sql_script, sql_asset, sql_ballad_plugin, sql_runtime, sql_artifacts }) |sql| {
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) == c.SQLITE_OK) {
                defer _ = c.sqlite3_finalize(stmt);
                _ = c.sqlite3_bind_text(stmt, 1, artifact_hash.ptr, @intCast(artifact_hash.len), transient);
                _ = c.sqlite3_step(stmt);
            }
        }
    }

    pub fn get_candidate_by_hash(self: StoreDriver, artifact_hash: []const u8) !?Candidate {
        const sql = "SELECT artifact_hash, name, version, kind, lua_abi, lua_api, runtime, runtime_artifact_hash, resolver, source, path FROM artifacts WHERE artifact_hash = ? LIMIT 1;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SQLitePrepareError;
        defer _ = c.sqlite3_finalize(stmt);

        const transient = moonstone_sqlite_transient_ptr;
        _ = c.sqlite3_bind_text(stmt, 1, artifact_hash.ptr, @intCast(artifact_hash.len), transient);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            return Candidate{
                .artifact_hash = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
                .name = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
                .version = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2))),
                .kind = try manifest.Kind.from_string(std.mem.span(c.sqlite3_column_text(stmt, 3))),
                .lua_abi = if (c.sqlite3_column_text(stmt, 4)) |a| try self.allocator.dupe(u8, std.mem.span(a)) else null,
                .lua_api = if (c.sqlite3_column_text(stmt, 5)) |a| try self.allocator.dupe(u8, std.mem.span(a)) else null,
                .runtime = if (c.sqlite3_column_text(stmt, 6)) |r| try self.allocator.dupe(u8, std.mem.span(r)) else null,
                .runtime_artifact_hash = if (c.sqlite3_column_text(stmt, 7)) |h| try self.allocator.dupe(u8, std.mem.span(h)) else null,
                .resolver = if (c.sqlite3_column_text(stmt, 8)) |r| try self.allocator.dupe(u8, std.mem.span(r)) else null,
                .source = if (c.sqlite3_column_text(stmt, 9)) |s| try self.allocator.dupe(u8, std.mem.span(s)) else null,
                .path = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 10))),
            };
        }

        return null;
    }

    pub fn findCandidates(self: StoreDriver, query: ArtifactQuery) ![]Candidate {
        var candidates = std.ArrayList(Candidate).empty;

        // Build dynamic WHERE clause
        var where_parts = std.ArrayList([]const u8).empty;
        defer where_parts.deinit(self.allocator);
        try where_parts.append(self.allocator, "name = ?");
        if (query.resolver) |_| try where_parts.append(self.allocator, "resolver = ?");
        if (query.kind) |_| try where_parts.append(self.allocator, "kind = ?");
        if (query.target) |_| try where_parts.append(self.allocator, "target = ?");
        if (query.lua_abi) |_| try where_parts.append(self.allocator, "lua_abi = ?");
        if (query.lua_api) |_| try where_parts.append(self.allocator, "lua_api = ?");
        if (query.runtime) |_| try where_parts.append(self.allocator, "runtime = ?");
        if (query.runtime_artifact_hash) |_| try where_parts.append(self.allocator, "runtime_artifact_hash = ?");
        if (query.native_compat_required) |_| try where_parts.append(self.allocator, "native_compat_required = ?");

        const where_clause = try std.mem.join(self.allocator, " AND ", where_parts.items);
        defer self.allocator.free(where_clause);

        const sql_text = try std.fmt.allocPrint(self.allocator, "SELECT artifact_hash, name, version, kind, lua_abi, lua_api, runtime, runtime_artifact_hash, resolver, source, path FROM artifacts WHERE {s} ORDER BY version DESC;", .{where_clause});
        defer self.allocator.free(sql_text);
        const sql = try self.allocator.dupeZ(u8, sql_text);
        defer self.allocator.free(sql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.SQLitePrepareError;
        defer _ = c.sqlite3_finalize(stmt);

        const transient = moonstone_sqlite_transient_ptr;
        var param_idx: c_int = 1;
        _ = c.sqlite3_bind_text(stmt, param_idx, query.name.ptr, @intCast(query.name.len), transient);
        param_idx += 1;
        if (query.resolver) |r| {
            _ = c.sqlite3_bind_text(stmt, param_idx, r.ptr, @intCast(r.len), transient);
            param_idx += 1;
        }
        if (query.kind) |k| {
            const kind_str = @tagName(k);
            _ = c.sqlite3_bind_text(stmt, param_idx, kind_str.ptr, @intCast(kind_str.len), transient);
            param_idx += 1;
        }
        if (query.target) |t| {
            _ = c.sqlite3_bind_text(stmt, param_idx, t.ptr, @intCast(t.len), transient);
            param_idx += 1;
        }
        if (query.lua_abi) |a| {
            _ = c.sqlite3_bind_text(stmt, param_idx, a.ptr, @intCast(a.len), transient);
            param_idx += 1;
        }
        if (query.lua_api) |a| {
            _ = c.sqlite3_bind_text(stmt, param_idx, a.ptr, @intCast(a.len), transient);
            param_idx += 1;
        }
        if (query.runtime) |r| {
            _ = c.sqlite3_bind_text(stmt, param_idx, r.ptr, @intCast(r.len), transient);
            param_idx += 1;
        }
        if (query.runtime_artifact_hash) |h| {
            _ = c.sqlite3_bind_text(stmt, param_idx, h.ptr, @intCast(h.len), transient);
            param_idx += 1;
        }
        if (query.native_compat_required) |n| {
            _ = c.sqlite3_bind_int(stmt, param_idx, if (n) 1 else 0);
            param_idx += 1;
        }

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try candidates.append(self.allocator, .{
                .artifact_hash = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
                .name = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
                .version = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2))),
                .kind = try manifest.Kind.from_string(std.mem.span(c.sqlite3_column_text(stmt, 3))),
                .lua_abi = if (c.sqlite3_column_text(stmt, 4)) |a| try self.allocator.dupe(u8, std.mem.span(a)) else null,
                .lua_api = if (c.sqlite3_column_text(stmt, 5)) |a| try self.allocator.dupe(u8, std.mem.span(a)) else null,
                .runtime = if (c.sqlite3_column_text(stmt, 6)) |r| try self.allocator.dupe(u8, std.mem.span(r)) else null,
                .runtime_artifact_hash = if (c.sqlite3_column_text(stmt, 7)) |h| try self.allocator.dupe(u8, std.mem.span(h)) else null,
                .resolver = if (c.sqlite3_column_text(stmt, 8)) |r| try self.allocator.dupe(u8, std.mem.span(r)) else null,
                .source = if (c.sqlite3_column_text(stmt, 9)) |s| try self.allocator.dupe(u8, std.mem.span(s)) else null,
                .path = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 10))),
            });
        }

        return try candidates.toOwnedSlice(self.allocator);
    }

    // Legacy alias for backward compatibility during transition
    pub fn find_candidates(self: StoreDriver, pkg_name: []const u8) ![]Candidate {
        return self.findCandidates(.{ .name = pkg_name });
    }

    pub fn get_artifact_path(self: StoreDriver, artifact_hash: []const u8) !?[]const u8 {
        const sql = "SELECT path FROM artifacts WHERE artifact_hash = ? LIMIT 1;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SQLitePrepareError;
        defer _ = c.sqlite3_finalize(stmt);

        const transient = moonstone_sqlite_transient_ptr;
        _ = c.sqlite3_bind_text(stmt, 1, artifact_hash.ptr, @intCast(artifact_hash.len), transient);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            return try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)));
        }
        return null;
    }
};
