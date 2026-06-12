const std = @import("std");
const manifest = @import("../domain/manifest.zig");
pub const resolver = @import("../resolution/root.zig");
const fs = @import("../platform/fs.zig");
const http = @import("../platform/http.zig");
const driver_mod = @import("../store/driver.zig");
const profiler = @import("../diagnostics/profiler.zig");

var registry_payload_cache: std.StringHashMapUnmanaged([]u8) = .empty;

/// Resolved registry entry ready for use by the client.
pub const ResolvedRegistry = struct {
    name: []const u8,
    url: []const u8,
    token: ?[]const u8,
    priority: i32,

    pub fn deinit(self: ResolvedRegistry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.url);
        if (self.token) |t| allocator.free(t);
    }
};

/// Free memory returned by a registry resolver.
pub fn deinitResolved(slice: []ResolvedRegistry, allocator: std.mem.Allocator) void {
    for (slice) |*r| r.deinit(allocator);
    allocator.free(slice);
}

// SQLite support for compact index queries
const c = driver_mod.c;

pub const RuntimeEntry = struct {

    name: []const u8,
    version: []const u8,
};

pub const RegistryClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    http_client: ?std.http.Client,
    registry_root: []const u8,
    is_remote: bool,
    token: ?[]const u8 = null,
    meta: ?manifest.RegistryRoot = null,
    env: ?*std.process.Environ.Map = null,
    on_event: ?resolver.ResolveCallback = null,
    on_event_context: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8, token: ?[]const u8, env: ?*std.process.Environ.Map) RegistryClient {
        const is_remote = std.mem.startsWith(u8, root, "http");
        return .{
            .allocator = allocator,
            .io = io,
            .http_client = if (is_remote) std.http.Client{
                .allocator = allocator,
                .io = io,
            } else null,
            .registry_root = root,
            .is_remote = is_remote,
            .token = token,
            .env = env,
        };
    }

    pub fn deinit(self: *RegistryClient) void {
        if (self.http_client) |*client| {
            client.deinit();
            self.http_client = null;
        }
    }

    pub fn ensure_meta(self: *RegistryClient) !void {
        if (self.meta != null) return;
        const content = try self.read_file_from_registry("registry.toml");
        defer self.allocator.free(content);
        self.meta = try manifest.RegistryRoot.parse(self.allocator, content);

        if (!std.mem.eql(u8, self.meta.?.registry.protocol, "moonstone.registry.v0")) {
            return error.UnsupportedRegistryProtocol;
        }
    }

    pub fn fetch_index(self: *RegistryClient) !manifest.RemotePackageStoreIndex {
        try self.ensure_meta();
        const index_sub_path = self.meta.?.index.url;
        const content = try self.read_file_from_registry(index_sub_path);
        defer self.allocator.free(content);

        // Verify index hash for v0
        var hash_buf: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(content, &hash_buf, .{});
        const actual_hex = std.fmt.bytesToHex(hash_buf, .lower);
        const actual_hash = try std.fmt.allocPrint(self.allocator, "b3:{s}", .{&actual_hex});
        defer self.allocator.free(actual_hash);

        if (!std.mem.eql(u8, actual_hash, self.meta.?.index.hash)) {

            return error.StoreIndexHashMismatch;
        }

        return try manifest.RemotePackageStoreIndex.parse(self.allocator, content);
    }

    pub fn fetch_private_index(self: *RegistryClient) !?manifest.RemotePackageStoreIndex {
        if (self.token == null or !self.is_remote) return null;
        const content = self.read_file_from_registry("private/index.toml") catch return null;
        defer self.allocator.free(content);
        return try manifest.RemotePackageStoreIndex.parse(self.allocator, content);
    }


    pub const CompactPackageVersion = struct { version: []const u8, descriptor: []const u8 };

    /// Query the compact SQLite index for all versions of a package.
    /// Returns a slice of version/descriptor pairs.
    /// Caller must call deinit on each entry and allocator.free on the slice.
    pub fn find_package_versions(self: *RegistryClient, cache_dir: []const u8, pkg_name: []const u8) ![]CompactPackageVersion {
        const sqlite_path = self.fetch_compact_index(cache_dir) catch |err| {
            if (err == error.CompactStoreIndexHashMismatch or err == error.ZstdDecompressionFailed or err == error.CompactStoreIndexContentHashMismatch) return err;
            return @as([]CompactPackageVersion, &.{});
        } orelse return @as([]CompactPackageVersion, &.{});
        defer self.allocator.free(sqlite_path);

        const sqlite_path_z = try self.allocator.dupeZ(u8, sqlite_path);
        defer self.allocator.free(sqlite_path_z);
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open(sqlite_path_z, &db) != c.SQLITE_OK) {
            return error.SQLiteOpenError;
        }
        defer _ = c.sqlite3_close(db);

        const sql = "SELECT version, descriptor FROM packages WHERE name = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SQLitePrepareError;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, pkg_name.ptr, @intCast(pkg_name.len), driver_mod.moonstone_sqlite_transient_ptr);

        var list = std.ArrayList(CompactPackageVersion).empty;
        errdefer {
            for (list.items) |item| {
                self.allocator.free(item.version);
                self.allocator.free(item.descriptor);
            }
            list.deinit(self.allocator);
        }

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const version = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)));
            const descriptor = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
            try list.append(self.allocator, .{ .version = version, .descriptor = descriptor });
        }
        return try list.toOwnedSlice(self.allocator);
    }

    /// Download and decompress the compact SQLite index if available.
    /// Returns the absolute path to the decompressed index.sqlite, or null if compact index is not offered.
    /// The caller owns the returned path memory.
    pub fn fetch_compact_index(self: *RegistryClient, cache_dir: []const u8) !?[]const u8 {
        try self.ensure_meta();
        const compact = self.meta.?.index.compact orelse return null;

        // Build per-registry cache path
        const reg_cache = try std.fs.path.join(self.allocator, &.{ cache_dir, "registries", self.meta.?.registry.id });
        defer self.allocator.free(reg_cache);
        try std.Io.Dir.cwd().createDirPath(self.io, reg_cache);

        const final_sqlite = try std.fs.path.join(self.allocator, &.{ reg_cache, "index.sqlite" });
        const tmp_zst = try std.fs.path.join(self.allocator, &.{ reg_cache, "index.sqlite.zst.tmp" });
        const tmp_sqlite = try std.fs.path.join(self.allocator, &.{ reg_cache, "index.sqlite.tmp" });
        defer self.allocator.free(tmp_zst);
        defer self.allocator.free(tmp_sqlite);

        // 1. Download compressed index
        const zst_bytes = try self.read_file_from_registry(compact.url);
        defer self.allocator.free(zst_bytes);

        // 2. Verify compressed hash
        var hash_buf: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(zst_bytes, &hash_buf, .{});
        const actual_hex = std.fmt.bytesToHex(hash_buf, .lower);
        const actual_hash = try std.fmt.allocPrint(self.allocator, "b3:{s}", .{&actual_hex});
        defer self.allocator.free(actual_hash);

        if (!std.mem.eql(u8, actual_hash, compact.compressed_hash)) {
            return error.CompactStoreIndexHashMismatch;
        }

        // 3. Write temp zst file
        const zst_file = try std.Io.Dir.cwd().createFile(self.io, tmp_zst, .{});
        try zst_file.writeStreamingAll(self.io, zst_bytes);
        zst_file.close(self.io);

        // 4. Decompress with zstd
        const zstd_res = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "zstd", "-d", "-f", "-o", tmp_sqlite, tmp_zst },
        });
        defer self.allocator.free(zstd_res.stdout);
        defer self.allocator.free(zstd_res.stderr);
        if (zstd_res.term != .exited or zstd_res.term.exited != 0) {
            return error.ZstdDecompressionFailed;
        }

        // 5. Verify content hash
        const sqlite_content = try std.Io.Dir.cwd().readFileAlloc(self.io, tmp_sqlite, self.allocator, std.Io.Limit.limited(100 * 1024 * 1024));
        defer self.allocator.free(sqlite_content);

        var content_hash_buf: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(sqlite_content, &content_hash_buf, .{});
        const content_hex = std.fmt.bytesToHex(content_hash_buf, .lower);
        const actual_content_hash = try std.fmt.allocPrint(self.allocator, "b3:{s}", .{&content_hex});
        defer self.allocator.free(actual_content_hash);

        if (!std.mem.eql(u8, actual_content_hash, compact.content_hash)) {
            return error.CompactStoreIndexContentHashMismatch;
        }

        // 6. Atomic replace
        try std.Io.Dir.renameAbsolute(tmp_sqlite, final_sqlite, self.io);
        try std.Io.Dir.cwd().deleteFile(self.io, tmp_zst);

        return final_sqlite;
    }

    pub fn fetch_descriptor(self: *RegistryClient, descriptor_path: []const u8) !manifest.RemotePackageDescriptor {
        const content = self.read_file_from_registry(descriptor_path) catch |err| {

            return err;
        };
        defer self.allocator.free(content);
        return try manifest.RemotePackageDescriptor.parse(self.allocator, content);
    }

    pub fn list_runtimes(self: *RegistryClient, cache_dir: []const u8) ![]RuntimeEntry {
        const sqlite_path = self.fetch_compact_index(cache_dir) catch null;
        if (sqlite_path) |sp| {
            defer self.allocator.free(sp);
            const sqlite_path_z = try self.allocator.dupeZ(u8, sp);
            defer self.allocator.free(sqlite_path_z);
            var db: ?*c.sqlite3 = null;
            if (c.sqlite3_open(sqlite_path_z, &db) != c.SQLITE_OK) {
                return error.SQLiteOpenError;
            }
            defer _ = c.sqlite3_close(db);

            const sql = "SELECT name, version FROM packages WHERE kind = 'runtime' ORDER BY name, version DESC;";
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SQLitePrepareError;
            defer _ = c.sqlite3_finalize(stmt);

            var list = std.ArrayList(RuntimeEntry).empty;
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                try list.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
                    .version = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
                });
            }
            return list.toOwnedSlice(self.allocator);
        }

        // Fallback to TOML index
        const idx = try self.fetch_index();
        var list = std.ArrayList(RuntimeEntry).empty;
        for (idx.package) |pkg| {
            if (pkg.kind == .runtime) {
                try list.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, pkg.name),
                    .version = try self.allocator.dupe(u8, pkg.version),
                });
            }
        }
        return list.toOwnedSlice(self.allocator);
    }

    pub fn fetch_blob(self: *RegistryClient, descriptor_path: []const u8, blob_rel_url: []const u8) ![]u8 {
        const is_relative_to_desc = std.mem.startsWith(u8, blob_rel_url, "../") or std.mem.startsWith(u8, blob_rel_url, "./");

        if (!self.is_remote and is_relative_to_desc) {
            const clean_root = if (std.mem.startsWith(u8, self.registry_root, "file:"))
                self.registry_root[5..]
            else
                self.registry_root;
            const final_root = if (std.mem.startsWith(u8, clean_root, "//"))
                clean_root[2..]
            else
                clean_root;

            const descriptor_abs = try std.fs.path.resolve(self.allocator, &.{ final_root, descriptor_path });
            defer self.allocator.free(descriptor_abs);
            const descriptor_abs_dir = std.fs.path.dirname(descriptor_abs) orelse final_root;
            const blob_abs = try std.fs.path.resolve(self.allocator, &.{ descriptor_abs_dir, blob_rel_url });
            defer self.allocator.free(blob_abs);

            return std.Io.Dir.cwd().readFileAlloc(self.io, blob_abs, self.allocator, std.Io.Limit.limited(50 * 1024 * 1024)) catch |err| {

                return err;
            };
        }

        return try self.read_file_from_registry(blob_rel_url);
    }

    fn read_file_from_registry(self: *RegistryClient, sub_path: []const u8) ![]u8 {
        const cache_key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ self.registry_root, sub_path });
        defer self.allocator.free(cache_key);
        if (registry_payload_cache.get(cache_key)) |cached| {
            profiler.mark("registry.payload.cache_hit");
            return try self.allocator.dupe(u8, cached);
        }

        const span = profiler.now();
        if (self.is_remote) {
            // Check if sub_path is already an absolute URL
            if (std.mem.startsWith(u8, sub_path, "http")) {
                const content = try self.get_url(sub_path);
                errdefer self.allocator.free(content);
                try registry_payload_cache.put(self.allocator, try self.allocator.dupe(u8, cache_key), try self.allocator.dupe(u8, content));
                profiler.span("registry.payload.fetch", span);
                return content;
            }
            const url = try std.fs.path.join(self.allocator, &.{ self.registry_root, sub_path });
            defer self.allocator.free(url);
            const content = try self.get_url(url);
            errdefer self.allocator.free(content);
            try registry_payload_cache.put(self.allocator, try self.allocator.dupe(u8, cache_key), try self.allocator.dupe(u8, content));
            profiler.span("registry.payload.fetch", span);
            return content;
        } else {
            const clean_root = if (std.mem.startsWith(u8, self.registry_root, "file:"))
                self.registry_root[5..]
            else
                self.registry_root;

            // Handle file:/// (triple slash)
            const final_root = if (std.mem.startsWith(u8, clean_root, "//"))
                clean_root[2..]
            else
                clean_root;

            // Resolve the path to clean up any '..' components, RELATIVE to registry root
            var path_parts = [_][]const u8{ final_root, sub_path };
            const full_path = try std.fs.path.resolve(self.allocator, &path_parts);
            defer self.allocator.free(full_path);

            const content = std.Io.Dir.cwd().readFileAlloc(self.io, full_path, self.allocator, std.Io.Limit.limited(50 * 1024 * 1024)) catch |err| {

                return err;
            };
            errdefer self.allocator.free(content);
            try registry_payload_cache.put(self.allocator, try self.allocator.dupe(u8, cache_key), try self.allocator.dupe(u8, content));
            profiler.span("registry.payload.read", span);
            return content;
        }
    }


    fn get_url_single(self: *RegistryClient, url: []const u8, timeout_ms: u32) ![]u8 {
        const client = &(self.http_client orelse return error.HttpClientNotInitialized);

        var extra_headers = std.ArrayList(std.http.Header).empty;
        defer extra_headers.deinit(self.allocator);

        if (self.token) |t| {
            const auth_val = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{t});
            defer self.allocator.free(auth_val);
            try extra_headers.append(self.allocator, .{ .name = "Authorization", .value = auth_val });
        }

        return http.fetchGetBodyWithClient(self.allocator, client, url, extra_headers.items, timeout_ms);
    }

    fn get_url(self: *RegistryClient, url: []const u8) ![]u8 {
        var temp_env = std.process.Environ.Map.init(self.allocator);
        defer temp_env.deinit();
        const env_to_use = self.env orelse &temp_env;
        const net_cfg = fs.get_network_config(self.allocator, env_to_use, self.io);
        const http_cfg = http.get_http_config(self.allocator, env_to_use, self.io);

        const max_retries = net_cfg.retries;
        const delay_seconds = net_cfg.retry_delay;

        var attempt: u32 = 0;
        while (true) {
            if (self.get_url_single(url, http_cfg.timeout_ms)) |data| {
                return data;
            } else |err| {
                attempt += 1;
                if (attempt > max_retries) {
                    return err;
                }

                if (self.on_event) |cb| {
                    cb(self.on_event_context, .{
                        .retry = .{
                            .url = url,
                            .err_name = @errorName(err),
                            .attempt = attempt,
                            .max_retries = max_retries,
                            .delay_seconds = delay_seconds,
                        },
                    });
                }

                std.Io.sleep(self.io, std.Io.Duration.fromSeconds(delay_seconds), .awake) catch {};
            }
        }
    }
};
