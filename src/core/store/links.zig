const std = @import("std");
const manifest = @import("../domain/manifest.zig");
const driver_mod = @import("driver.zig");

const c = driver_mod.c;

pub const LinkMode = enum {
    live,
    artifact,

    pub fn fromString(text: []const u8) !LinkMode {
        if (std.mem.eql(u8, text, "live")) return .live;
        if (std.mem.eql(u8, text, "artifact")) return .artifact;
        return error.InvalidLinkMode;
    }

    pub fn asString(self: LinkMode) []const u8 {
        return switch (self) {
            .live => "live",
            .artifact => "artifact",
        };
    }
};

/// Borrowed input used when registering a link.
/// The caller owns these slices.
pub const LinkRegistration = struct {
    name: []const u8,
    path: []const u8,
    version: []const u8,
    kind: manifest.Kind,
    mode: LinkMode = .live,
};

/// Owned result returned from SQLite.
/// Call deinit() when done.
pub const LinkEntry = struct {
    name: []const u8,
    path: []const u8,
    version: []const u8,
    kind: manifest.Kind,
    mode: LinkMode,
    registered_at: []const u8,

    pub fn deinit(self: *LinkEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.version);
        allocator.free(self.registered_at);
    }
};

pub fn deinitEntries(entries: []LinkEntry, allocator: std.mem.Allocator) void {
    for (entries) |*entry| {
        entry.deinit(allocator);
    }
    allocator.free(entries);
}


pub const LinkStore = struct {
    driver: *driver_mod.StoreDriver,

    pub fn init(driver: *driver_mod.StoreDriver) LinkStore {
        return .{ .driver = driver };
    }

    fn allocator(self: LinkStore) std.mem.Allocator {
        return self.driver.allocator;
    }

    fn db(self: LinkStore) !*c.sqlite3 {
        return try self.driver.getDb();
    }

    /// Register or replace a link.
    ///
    /// This does not create an artifact.
    /// This does not produce an artifact_hash.
    /// This only records a mutable local project pointer.
    pub fn register(self: LinkStore, entry: LinkRegistration) !void {
        try self.driver.exec(
            \\INSERT OR REPLACE INTO links
            \\  (name, path, version, kind, mode)
            \\VALUES (?, ?, ?, ?, ?);
        ,
            .{
                entry.name,
                entry.path,
                entry.version,
                @tagName(entry.kind),
                entry.mode.asString(),
            },
        );
    }

    /// Same as register(), but preserves an explicit timestamp.
    /// Useful when migrating legacy link.toml files.
    pub fn registerWithTimestamp(
        self: LinkStore,
        entry: LinkRegistration,
        registered_at: []const u8,
    ) !void {
        try self.driver.exec(
            \\INSERT OR REPLACE INTO links
            \\  (name, path, version, kind, mode, registered_at)
            \\VALUES (?, ?, ?, ?, ?, ?);
        ,
            .{
                entry.name,
                entry.path,
                entry.version,
                @tagName(entry.kind),
                entry.mode.asString(),
                registered_at,
            },
        );
    }

    pub fn unregister(self: LinkStore, name: []const u8) !void {
        try self.driver.exec(
            "DELETE FROM links WHERE name = ?;",
            .{name},
        );
    }

    pub fn get(self: LinkStore, name: []const u8) !?LinkEntry {
        const sql =
            \\SELECT name, path, version, kind, mode, registered_at
            \\FROM links
            \\WHERE name = ?
            \\LIMIT 1;
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(try self.db(), sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SQLitePrepareError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const transient = driver_mod.moonstone_sqlite_transient_ptr;
        _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), transient);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            return try self.readLinkEntry(stmt);
        }

        return null;
    }

    pub fn list(self: LinkStore) ![]LinkEntry {
        var out = std.ArrayList(LinkEntry).empty;

        const sql =
            \\SELECT name, path, version, kind, mode, registered_at
            \\FROM links
            \\ORDER BY name ASC;
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(try self.db(), sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SQLitePrepareError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try out.append(self.allocator(), try self.readLinkEntry(stmt));
        }

        return out.toOwnedSlice(self.allocator());
    }

    pub fn findByName(self: LinkStore, name: []const u8) ![]const LinkEntry {
        var out = std.ArrayList(LinkEntry).empty;

        const sql =
            \\SELECT name, path, version, kind, mode, registered_at
            \\FROM links
            \\WHERE name = ?
            \\ORDER BY version DESC;
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(try self.db(), sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SQLitePrepareError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const transient = driver_mod.moonstone_sqlite_transient_ptr;
        _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), transient);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try out.append(self.allocator(), try self.readLinkEntry(stmt));
        }

        return out.toOwnedSlice(self.allocator());
    }

    pub fn clearLinks(self: LinkStore) !void {
        try self.driver.execRaw("DELETE FROM links;");
    }

    fn readLinkEntry(self: LinkStore, stmt: ?*c.sqlite3_stmt) !LinkEntry {
        const kind_text = std.mem.span(c.sqlite3_column_text(stmt, 3));
        const mode_text = std.mem.span(c.sqlite3_column_text(stmt, 4));

        return .{
            .name = try self.allocator().dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
            .path = try self.allocator().dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
            .version = try self.allocator().dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2))),
            .kind = try manifest.Kind.from_string(kind_text),
            .mode = try LinkMode.fromString(mode_text),
            .registered_at = try self.allocator().dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 5))),
        };
    }

    /// Migration helper for the old on-disk link.toml directory layout.
    /// This imports legacy files into the SQLite links table.
    pub fn loadLegacyDir(self: LinkStore, dir_path: []const u8, io: std.Io) !void {
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |sub_entry| {
            if (sub_entry.kind != .directory) continue;

            const link_file = try std.fs.path.join(
                self.allocator(),
                &.{ dir_path, sub_entry.name, "link.toml" },
            );
            defer self.allocator().free(link_file);

            const content = std.Io.Dir.cwd().readFileAlloc(
                io,
                link_file,
                self.allocator(),
                std.Io.Limit.limited(1024 * 1024),
            ) catch |err| {
                if (err == error.FileNotFound) continue;
                return err;
            };
            defer self.allocator().free(content);

            var legacy = try parseLegacyEntry(self.allocator(), content);
            defer legacy.deinit(self.allocator());

            if (legacy.registered_at) |registered_at| {
                try self.registerWithTimestamp(legacy.registration, registered_at);
            } else {
                try self.register(legacy.registration);
            }
        }
    }
};

const LegacyEntry = struct {
    registration: LinkRegistration,
    registered_at: ?[]const u8,

    pub fn deinit(self: *LegacyEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.registration.name);
        allocator.free(self.registration.path);
        allocator.free(self.registration.version);
        if (self.registered_at) |registered_at| allocator.free(registered_at);
    }
};

fn parseLegacyEntry(allocator: std.mem.Allocator, content: []const u8) !LegacyEntry {
    var name: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var registered_at: ?[]const u8 = null;
    var mode_text: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var kind_text: ?[]const u8 = null;

    errdefer {
        if (name) |v| allocator.free(v);
        if (path) |v| allocator.free(v);
        if (registered_at) |v| allocator.free(v);
        if (mode_text) |v| allocator.free(v);
        if (version) |v| allocator.free(v);
        if (kind_text) |v| allocator.free(v);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    var in_link = false;
    var in_package = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;

        if (std.mem.eql(u8, trimmed, "[link]")) {
            in_link = true;
            in_package = false;
            continue;
        }

        if (std.mem.eql(u8, trimmed, "[package]")) {
            in_link = false;
            in_package = true;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "[")) {
            in_link = false;
            in_package = false;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t\"");
        const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t\"");

        if (in_link) {
            if (std.mem.eql(u8, key, "name")) {
                if (name) |old| allocator.free(old);
                name = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "path")) {
                if (path) |old| allocator.free(old);
                path = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "registered_at")) {
                if (registered_at) |old| allocator.free(old);
                registered_at = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "mode")) {
                if (mode_text) |old| allocator.free(old);
                mode_text = try allocator.dupe(u8, value);
            }
        } else if (in_package) {
            if (std.mem.eql(u8, key, "version")) {
                if (version) |old| allocator.free(old);
                version = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "kind")) {
                if (kind_text) |old| allocator.free(old);
                kind_text = try allocator.dupe(u8, value);
            }
        }
    }

    const final_name = name orelse return error.MissingName;
    const final_path = path orelse return error.MissingPath;
    const final_version = version orelse try allocator.dupe(u8, "unknown");

    const final_kind = if (kind_text) |k|
        try manifest.Kind.from_string(k)
    else
        .lib;

    const final_mode = if (mode_text) |m|
        try LinkMode.fromString(m)
    else
        .live;

    if (kind_text) |k| allocator.free(k);
    if (mode_text) |m| allocator.free(m);

    return .{
        .registration = .{
            .name = final_name,
            .path = final_path,
            .version = final_version,
            .kind = final_kind,
            .mode = final_mode,
        },
        .registered_at = registered_at,
    };
}
