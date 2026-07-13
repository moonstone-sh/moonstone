const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

fn hashHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytes, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);
    return std.fmt.allocPrint(allocator, "b3:{s}", .{&hex});
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(100 * 1024 * 1024));
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn mkdirp(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
}

fn dirname(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

fn stripHashPrefix(hash: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, hash, "b3:")) hash[3..] else hash;
}

fn blobRelPath(allocator: std.mem.Allocator, hash: []const u8, ext: []const u8) ![]const u8 {
    const hex = stripHashPrefix(hash);
    const a = if (hex.len >= 2) hex[0..2] else "00";
    const b = if (hex.len >= 4) hex[2..4] else "00";
    return try std.fmt.allocPrint(allocator, "blobs/b3/{s}/{s}/{s}{s}", .{ a, b, hex, ext });
}

fn descriptorPath(allocator: std.mem.Allocator, registry: []const u8, name: []const u8, version: []const u8) ![]const u8 {
    return try std.fs.path.join(allocator, &.{ registry, "packages", name, version, "package.toml" });
}

fn descriptorRelPath(allocator: std.mem.Allocator, name: []const u8, version: []const u8) ![]const u8 {
    return try std.fs.path.join(allocator, &.{ "packages", name, version, "package.toml" });
}

fn packageKindString(kind: moonstone.domain.manifest.Kind) []const u8 {
    return switch (kind) {
        .script => "script",
        .lib => "lib",
        .bin => "bin",
        .runtime => "runtime",
    };
}

fn fileExt(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".tar.zst")) return ".tar.zst";
    if (std.mem.endsWith(u8, path, ".tar.zstd")) return ".tar.zstd";
    if (std.mem.endsWith(u8, path, ".tar.gz")) return ".tar.gz";
    if (std.mem.endsWith(u8, path, ".zip")) return ".zip";
    return "";
}

fn copyFile(allocator: std.mem.Allocator, io: std.Io, src: []const u8, dst: []const u8) !void {
    try mkdirp(io, dirname(dst));
    const data = try readFile(allocator, io, src);
    defer allocator.free(data);
    try writeFile(io, dst, data);
}

fn maybeDeleteFile(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| if (err != error.FileNotFound) return err;
}

fn artifactPath(allocator: std.mem.Allocator, registry: []const u8, rel: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, rel, "blobs/")) return null;
    return try std.fs.path.join(allocator, &.{ registry, rel });
}

fn replaceFirstStringAssignment(allocator: std.mem.Allocator, content: []const u8, key: []const u8, value: []const u8) ![]const u8 {
    const needle = try std.fmt.allocPrint(allocator, "{s} = \"", .{key});
    defer allocator.free(needle);
    if (std.mem.indexOf(u8, content, needle)) |start| {
        const value_start = start + needle.len;
        if (std.mem.indexOfScalarPos(u8, content, value_start, '"')) |end| {
            var out = std.ArrayList(u8).empty;
            try out.appendSlice(allocator, content[0..value_start]);
            try out.appendSlice(allocator, value);
            try out.appendSlice(allocator, content[end..]);
            return try out.toOwnedSlice(allocator);
        }
    }
    return try allocator.dupe(u8, content);
}

fn rewriteBlobMetadata(allocator: std.mem.Allocator, descriptor: []const u8, blob_rel: []const u8, blob_hash: []const u8) ![]const u8 {
    // Ballad already emits the correct relative blob path. For descriptors produced elsewhere,
    // rewrite the first artifact url/hash assignment as a convenience for local registry push.
    const with_url = if (std.mem.indexOf(u8, descriptor, "url = \"blobs/")) |_| try allocator.dupe(u8, descriptor) else try replaceFirstStringAssignment(allocator, descriptor, "url", blob_rel);
    defer allocator.free(with_url);
    return try replaceFirstStringAssignment(allocator, with_url, "hash", blob_hash);
}

fn rewriteBlobUrlIfNeeded(allocator: std.mem.Allocator, descriptor: []const u8, blob_rel: []const u8) ![]const u8 {
    // Keep this helper for old call sites/tests that only need URL normalization.
    if (std.mem.indexOf(u8, descriptor, "url = \"blobs/")) |_| return try allocator.dupe(u8, descriptor);
    if (std.mem.indexOf(u8, descriptor, "url = \"")) |start| {
        const value_start = start + "url = \"".len;
        if (std.mem.indexOfScalarPos(u8, descriptor, value_start, '"')) |end| {
            var out = std.ArrayList(u8).empty;
            try out.appendSlice(allocator, descriptor[0..value_start]);
            try out.appendSlice(allocator, blob_rel);
            try out.appendSlice(allocator, descriptor[end..]);
            return try out.toOwnedSlice(allocator);
        }
    }
    return try allocator.dupe(u8, descriptor);
}

fn syncRegistry(allocator: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, registry: []const u8, name_for_root: []const u8) !void {
    const packages_root = try std.fs.path.join(allocator, &.{ registry, "packages" });
    defer allocator.free(packages_root);
    try mkdirp(io, packages_root);

    var index_entries = std.ArrayList([]const u8).empty;
    defer {
        for (index_entries.items) |entry| allocator.free(entry);
        index_entries.deinit(allocator);
    }

    var packages_dir = try std.Io.Dir.cwd().openDir(io, packages_root, .{ .iterate = true });
    defer packages_dir.close(io);
    var pkg_it = packages_dir.iterate();
    while (try pkg_it.next(io)) |pkg_entry| {
        if (pkg_entry.kind != .directory) continue;
        const pkg_root = try std.fs.path.join(allocator, &.{ packages_root, pkg_entry.name });
        defer allocator.free(pkg_root);
        var ns_dir = try std.Io.Dir.cwd().openDir(io, pkg_root, .{ .iterate = true });
        defer ns_dir.close(io);
        var ns_it = ns_dir.iterate();
        while (try ns_it.next(io)) |name_entry| {
            if (name_entry.kind != .directory) continue;
            const full_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkg_entry.name, name_entry.name });
            defer allocator.free(full_name);
            const full_name_root = try std.fs.path.join(allocator, &.{ pkg_root, name_entry.name });
            defer allocator.free(full_name_root);
            var versions_dir = try std.Io.Dir.cwd().openDir(io, full_name_root, .{ .iterate = true });
            defer versions_dir.close(io);
            var ver_it = versions_dir.iterate();
            while (try ver_it.next(io)) |ver_entry| {
                if (ver_entry.kind != .directory) continue;
                const desc_abs = try descriptorPath(allocator, registry, full_name, ver_entry.name);
                defer allocator.free(desc_abs);
                const desc = readFile(allocator, io, desc_abs) catch continue;
                defer allocator.free(desc);
                var parsed = moonstone.domain.manifest.RemotePackageDescriptor.parse(allocator, desc) catch continue;
                defer parsed.deinit(allocator);
                const desc_hash = try hashHexAlloc(allocator, desc);
                defer allocator.free(desc_hash);
                const rel = try descriptorRelPath(allocator, parsed.package.name, parsed.package.version);
                defer allocator.free(rel);
                const entry = try std.fmt.allocPrint(allocator, "[[package]]\nname = \"{s}\"\nversion = \"{s}\"\nkind = \"{s}\"\ndescriptor = \"{s}\"\ndescriptor_hash = \"{s}\"\n\n", .{ parsed.package.name, parsed.package.version, packageKindString(parsed.package.kind), rel, desc_hash });
                try index_entries.append(allocator, entry);
            }
        }
    }

    std.mem.sort([]const u8, index_entries.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    for (index_entries.items) |entry| try aw.writer.writeAll(entry);
    try aw.writer.flush();
    const index_bytes = aw.writer.buffer[0..aw.writer.end];
    const index_path = try std.fs.path.join(allocator, &.{ registry, "index.toml" });
    defer allocator.free(index_path);
    try writeFile(io, index_path, index_bytes);
    const index_hash = try hashHexAlloc(allocator, index_bytes);
    defer allocator.free(index_hash);

    // Build SQLite compact index
    const sqlite_path = try std.fs.path.join(allocator, &.{ registry, "index.sqlite" });
    defer allocator.free(sqlite_path);
    try maybeDeleteFile(io, sqlite_path);

    const sqlite_driver = moonstone.store.driver;
    const sqlite_path_z = try allocator.dupeZ(u8, sqlite_path);
    defer allocator.free(sqlite_path_z);

    var db: *sqlite_driver.c.sqlite3 = undefined;
    const rc = sqlite_driver.c.sqlite3_open_v2(sqlite_path_z, @ptrCast(&db), sqlite_driver.c.SQLITE_OPEN_READWRITE | sqlite_driver.c.SQLITE_OPEN_CREATE, null);
    if (rc != sqlite_driver.c.SQLITE_OK) return error.SqliteOpenFailed;

    const schema =
        \\CREATE TABLE packages (name TEXT NOT NULL, version TEXT NOT NULL, kind TEXT NOT NULL, descriptor TEXT NOT NULL, descriptor_hash TEXT NOT NULL, yanked INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (name, version));
        \\CREATE TABLE artifacts (name TEXT NOT NULL, version TEXT NOT NULL, artifact_hash TEXT NOT NULL, target TEXT, lua_abi TEXT, url TEXT NOT NULL, bytes INTEGER, format TEXT NOT NULL, PRIMARY KEY (name, version, artifact_hash));
        \\CREATE TABLE provides_lua (artifact_hash TEXT NOT NULL, module TEXT NOT NULL, path TEXT NOT NULL, lua_abi TEXT, PRIMARY KEY (artifact_hash, module));
    ;
    if (sqlite_driver.c.sqlite3_exec(db, schema, null, null, null) != sqlite_driver.c.SQLITE_OK) return error.SqliteSchemaFailed;
    _ = sqlite_driver.c.sqlite3_exec(db, "BEGIN TRANSACTION;", null, null, null);

    var stmt_pkg: *sqlite_driver.c.sqlite3_stmt = undefined;
    if (sqlite_driver.c.sqlite3_prepare_v2(db, "INSERT INTO packages (name, version, kind, descriptor, descriptor_hash) VALUES (?, ?, ?, ?, ?);", -1, @ptrCast(&stmt_pkg), null) != sqlite_driver.c.SQLITE_OK) return error.SqlitePrepareFailed;
    defer _ = sqlite_driver.c.sqlite3_finalize(stmt_pkg);

    var stmt_art: *sqlite_driver.c.sqlite3_stmt = undefined;
    if (sqlite_driver.c.sqlite3_prepare_v2(db, "INSERT INTO artifacts (name, version, artifact_hash, target, lua_abi, url, bytes, format) VALUES (?, ?, ?, ?, ?, ?, ?, ?);", -1, @ptrCast(&stmt_art), null) != sqlite_driver.c.SQLITE_OK) return error.SqlitePrepareFailed;
    defer _ = sqlite_driver.c.sqlite3_finalize(stmt_art);

    var stmt_prov: *sqlite_driver.c.sqlite3_stmt = undefined;
    if (sqlite_driver.c.sqlite3_prepare_v2(db, "INSERT INTO provides_lua (artifact_hash, module, path, lua_abi) VALUES (?, ?, ?, ?);", -1, @ptrCast(&stmt_prov), null) != sqlite_driver.c.SQLITE_OK) return error.SqlitePrepareFailed;
    defer _ = sqlite_driver.c.sqlite3_finalize(stmt_prov);

    const transient = sqlite_driver.moonstone_sqlite_transient_ptr;
    var pkg_it_sql = try std.Io.Dir.cwd().openDir(io, packages_root, .{ .iterate = true });
    defer pkg_it_sql.close(io);
    var pkg_it_s = pkg_it_sql.iterate();
    while (try pkg_it_s.next(io)) |pkg_entry| {
        if (pkg_entry.kind != .directory) continue;
        const pkg_root = try std.fs.path.join(allocator, &.{ packages_root, pkg_entry.name });
        defer allocator.free(pkg_root);
        var ns_dir = try std.Io.Dir.cwd().openDir(io, pkg_root, .{ .iterate = true });
        defer ns_dir.close(io);
        var ns_it = ns_dir.iterate();
        while (try ns_it.next(io)) |name_entry| {
            if (name_entry.kind != .directory) continue;
            const full_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkg_entry.name, name_entry.name });
            defer allocator.free(full_name);
            const full_name_root = try std.fs.path.join(allocator, &.{ pkg_root, name_entry.name });
            defer allocator.free(full_name_root);
            var versions_dir = try std.Io.Dir.cwd().openDir(io, full_name_root, .{ .iterate = true });
            defer versions_dir.close(io);
            var ver_it = versions_dir.iterate();
            while (try ver_it.next(io)) |ver_entry| {
                if (ver_entry.kind != .directory) continue;
                const desc_abs = try descriptorPath(allocator, registry, full_name, ver_entry.name);
                defer allocator.free(desc_abs);
                const desc = readFile(allocator, io, desc_abs) catch continue;
                defer allocator.free(desc);
                var parsed = moonstone.domain.manifest.RemotePackageDescriptor.parse(allocator, desc) catch continue;
                defer parsed.deinit(allocator);
                const desc_hash = try hashHexAlloc(allocator, desc);
                defer allocator.free(desc_hash);
                const rel = try descriptorRelPath(allocator, parsed.package.name, parsed.package.version);
                defer allocator.free(rel);

                _ = sqlite_driver.c.sqlite3_bind_text(stmt_pkg, 1, parsed.package.name.ptr, @intCast(parsed.package.name.len), transient);
                _ = sqlite_driver.c.sqlite3_bind_text(stmt_pkg, 2, parsed.package.version.ptr, @intCast(parsed.package.version.len), transient);
                const kind_str = packageKindString(parsed.package.kind);
                _ = sqlite_driver.c.sqlite3_bind_text(stmt_pkg, 3, kind_str.ptr, @intCast(kind_str.len), transient);
                _ = sqlite_driver.c.sqlite3_bind_text(stmt_pkg, 4, rel.ptr, @intCast(rel.len), transient);
                _ = sqlite_driver.c.sqlite3_bind_text(stmt_pkg, 5, desc_hash.ptr, @intCast(desc_hash.len), transient);
                _ = sqlite_driver.c.sqlite3_step(stmt_pkg);
                _ = sqlite_driver.c.sqlite3_reset(stmt_pkg);

                for (parsed.artifact) |art| {
                    _ = sqlite_driver.c.sqlite3_bind_text(stmt_art, 1, parsed.package.name.ptr, @intCast(parsed.package.name.len), transient);
                    _ = sqlite_driver.c.sqlite3_bind_text(stmt_art, 2, parsed.package.version.ptr, @intCast(parsed.package.version.len), transient);
                    _ = sqlite_driver.c.sqlite3_bind_text(stmt_art, 3, art.hash.ptr, @intCast(art.hash.len), transient);
                    if (art.target.len > 0) _ = sqlite_driver.c.sqlite3_bind_text(stmt_art, 4, art.target.ptr, @intCast(art.target.len), transient) else _ = sqlite_driver.c.sqlite3_bind_null(stmt_art, 4);
                    if (art.lua_abi.len > 0) _ = sqlite_driver.c.sqlite3_bind_text(stmt_art, 5, art.lua_abi.ptr, @intCast(art.lua_abi.len), transient) else _ = sqlite_driver.c.sqlite3_bind_null(stmt_art, 5);
                    _ = sqlite_driver.c.sqlite3_bind_text(stmt_art, 6, art.url.ptr, @intCast(art.url.len), transient);
                    if (art.bytes) |b| _ = sqlite_driver.c.sqlite3_bind_int64(stmt_art, 7, @intCast(b)) else _ = sqlite_driver.c.sqlite3_bind_null(stmt_art, 7);
                    _ = sqlite_driver.c.sqlite3_bind_text(stmt_art, 8, art.format.ptr, @intCast(art.format.len), transient);
                    _ = sqlite_driver.c.sqlite3_step(stmt_art);
                    _ = sqlite_driver.c.sqlite3_reset(stmt_art);

                    const all_provs = [_][]const moonstone.domain.manifest.FeatureProvision{ art.provides.lua_module, art.provides.lua_cmodule };
                    for (all_provs) |provs| {
                        for (provs) |prov| {
                            _ = sqlite_driver.c.sqlite3_bind_text(stmt_prov, 1, art.hash.ptr, @intCast(art.hash.len), transient);
                            _ = sqlite_driver.c.sqlite3_bind_text(stmt_prov, 2, prov.name.ptr, @intCast(prov.name.len), transient);
                            _ = sqlite_driver.c.sqlite3_bind_text(stmt_prov, 3, prov.path.ptr, @intCast(prov.path.len), transient);
                            if (art.lua_abi.len > 0) _ = sqlite_driver.c.sqlite3_bind_text(stmt_prov, 4, art.lua_abi.ptr, @intCast(art.lua_abi.len), transient) else _ = sqlite_driver.c.sqlite3_bind_null(stmt_prov, 4);
                            _ = sqlite_driver.c.sqlite3_step(stmt_prov);
                            _ = sqlite_driver.c.sqlite3_reset(stmt_prov);
                        }
                    }
                }
            }
        }
    }
    _ = sqlite_driver.c.sqlite3_exec(db, "COMMIT;", null, null, null);
    _ = sqlite_driver.c.sqlite3_close(db);

    const sqlite_bytes = try readFile(allocator, io, sqlite_path);
    defer allocator.free(sqlite_bytes);
    const content_hash = try hashHexAlloc(allocator, sqlite_bytes);
    defer allocator.free(content_hash);

    const zst_path = try std.fs.path.join(allocator, &.{ registry, "index.sqlite.zst" });
    defer allocator.free(zst_path);
    try maybeDeleteFile(io, zst_path);

    const zstd_res = try std.process.run(allocator, io, .{
        .argv = &.{ "zstd", "-q", "-f", sqlite_path, "-o", zst_path },
    });
    defer allocator.free(zstd_res.stdout);
    defer allocator.free(zstd_res.stderr);
    if (zstd_res.term != .exited or zstd_res.term.exited != 0) return error.ZstdCompressionFailed;

    const zst_bytes = try readFile(allocator, io, zst_path);
    defer allocator.free(zst_bytes);
    const compressed_hash = try hashHexAlloc(allocator, zst_bytes);
    defer allocator.free(compressed_hash);

    try maybeDeleteFile(io, sqlite_path);

    const registry_toml = try std.fmt.allocPrint(allocator, "[registry]\nid = \"{s}\"\nname = \"{s}\"\nprotocol = \"moonstone.registry.v0\"\nrevision = 1\ngenerated_at = \"local\"\nmin_client = \"0.1.0\"\n\n[index]\nformat = \"moonstone.index.v0\"\nurl = \"index.toml\"\nhash = \"{s}\"\nbytes = {d}\nrevision = 1\n\n[index.compact]\nformat = \"moonstone.index.sqlite.v0\"\nurl = \"index.sqlite.zst\"\ncompressed_hash = \"{s}\"\ncontent_hash = \"{s}\"\nbytes = {d}\n\n[blobs]\nalgorithm = \"b3\"\nlayout = \"blobs/b3/{{h0h1}}/{{h2h3}}/{{hash}}\"\n\n[capabilities]\nruntimes = true\nartifacts = true\nsource_packages = true\nrocks_bridge = false\nprivate = false\n", .{ name_for_root, name_for_root, index_hash, index_bytes.len, compressed_hash, content_hash, zst_bytes.len });
    defer allocator.free(registry_toml);
    const root_path = try std.fs.path.join(allocator, &.{ registry, "registry.toml" });
    defer allocator.free(root_path);
    try writeFile(io, root_path, registry_toml);
    try stdout.print("Synced registry {s}: {d} package versions (built index.toml & index.sqlite.zst).\n", .{ registry, index_entries.items.len });
}

pub const RegistryCreateCommand = struct {
    pub const name = "create";
    pub const description = "Create a local file registry";
    positionals: []const []const u8 = &.{},
    name_arg: ?[]const u8 = null,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon registry create <path> [name]
            \\
            \\Create a local file registry with registry.toml, index.toml,
            \\packages/, and blobs/.
            \\
            \\Flags:
            \\  --name-arg <name>    Registry name when not passed positionally
            \\
        , .{});
    }

    pub fn run(self: RegistryCreateCommand, ctx: *router.Context) !void {
        if (self.positionals.len < 1) return error.MissingArgument;
        const path = self.positionals[0];
        const r_name = self.name_arg orelse if (self.positionals.len >= 2) self.positionals[1] else "local";
        try mkdirp(ctx.io, path);
        const packages_path = try std.fs.path.join(ctx.allocator, &.{ path, "packages" });
        defer ctx.allocator.free(packages_path);
        const blobs_path = try std.fs.path.join(ctx.allocator, &.{ path, "blobs", "b3" });
        defer ctx.allocator.free(blobs_path);
        try mkdirp(ctx.io, packages_path);
        try mkdirp(ctx.io, blobs_path);
        try syncRegistry(ctx.allocator, ctx.io, ctx.stdout, path, r_name);
    }
};

pub const RegistrySyncCommand = struct {
    pub const name = "sync";
    pub const description = "Regenerate a local registry index";
    positionals: []const []const u8 = &.{},
    name_arg: ?[]const u8 = null,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon registry sync <path> [name]
            \\
            \\Delete and regenerate index.toml from packages/*/*/*/package.toml,
            \\then refresh registry.toml metadata.
            \\
            \\Flags:
            \\  --name-arg <name>    Registry name when not passed positionally
            \\
        , .{});
    }

    pub fn run(self: RegistrySyncCommand, ctx: *router.Context) !void {
        if (self.positionals.len < 1) return error.MissingArgument;
        const r_name = self.name_arg orelse if (self.positionals.len >= 2) self.positionals[1] else "local";
        try syncRegistry(ctx.allocator, ctx.io, ctx.stdout, self.positionals[0], r_name);
    }
};

pub const RegistryPushCommand = struct {
    pub const name = "push";
    pub const description = "Push a descriptor and blob into a local registry";
    positionals: []const []const u8 = &.{},
    registry: ?[]const u8 = null,
    descriptor: ?[]const u8 = null,
    blob: ?[]const u8 = null,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon registry push [registry] --descriptor <package.toml> --blob <archive>
            \\
            \\Copy a package descriptor and blob into a local file registry,
            \\rewrite the artifact url to the local blob path when needed,
            \\and regenerate index.toml.
            \\
            \\Flags:
            \\  --registry <path>       Local registry root
            \\  --descriptor <path>     package.toml descriptor
            \\  --blob <path>           Artifact/source archive
            \\
        , .{});
    }

    pub fn run(self: RegistryPushCommand, ctx: *router.Context) !void {
        const registry = self.registry orelse if (self.positionals.len >= 1) self.positionals[0] else return error.MissingArgument;
        const descriptor = self.descriptor orelse if (self.positionals.len >= 2) self.positionals[1] else return error.MissingArgument;
        const blob = self.blob orelse if (self.positionals.len >= 3) self.positionals[2] else return error.MissingArgument;
        const desc_bytes = try readFile(ctx.allocator, ctx.io, descriptor);
        defer ctx.allocator.free(desc_bytes);
        var parsed = try moonstone.domain.manifest.RemotePackageDescriptor.parse(ctx.allocator, desc_bytes);
        defer parsed.deinit(ctx.allocator);
        const blob_bytes = try readFile(ctx.allocator, ctx.io, blob);
        defer ctx.allocator.free(blob_bytes);
        const blob_hash = try hashHexAlloc(ctx.allocator, blob_bytes);
        defer ctx.allocator.free(blob_hash);
        const blob_rel = try blobRelPath(ctx.allocator, blob_hash, fileExt(blob));
        defer ctx.allocator.free(blob_rel);
        const blob_abs = try std.fs.path.join(ctx.allocator, &.{ registry, blob_rel });
        defer ctx.allocator.free(blob_abs);
        try copyFile(ctx.allocator, ctx.io, blob, blob_abs);
        const rewritten = try rewriteBlobMetadata(ctx.allocator, desc_bytes, blob_rel, blob_hash);
        defer ctx.allocator.free(rewritten);
        const desc_abs = try descriptorPath(ctx.allocator, registry, parsed.package.name, parsed.package.version);
        defer ctx.allocator.free(desc_abs);
        try mkdirp(ctx.io, dirname(desc_abs));
        try writeFile(ctx.io, desc_abs, rewritten);
        try syncRegistry(ctx.allocator, ctx.io, ctx.stdout, registry, "local");
        try ctx.stdout.print("Pushed {s}@{s} to {s}.\n", .{ parsed.package.name, parsed.package.version, registry });
    }
};

pub const RegistryPurgeCommand = struct {
    pub const name = "purge";
    pub const description = "Remove package descriptors from a local registry";
    positionals: []const []const u8 = &.{},
    registry: ?[]const u8 = null,
    p_name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    descriptor: ?[]const u8 = null,
    blob: ?[]const u8 = null,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon registry purge [registry] --descriptor <package.toml> [--blob <archive>]
            \\       moon registry purge [registry] --p-name <name> [--version <version>]
            \\
            \\Remove a package descriptor from a local file registry and
            \\regenerate index.toml. With --descriptor, local blob urls from
            \\the descriptor are also removed. With --blob, that blob is
            \\removed by content hash.
            \\
            \\Flags:
            \\  --registry <path>       Local registry root
            \\  --descriptor <path>     package.toml descriptor to derive package/version
            \\  --blob <path>           Artifact/source archive to remove by hash
            \\  --p-name <name>         Package name fallback
            \\  --version <version>     Package version fallback
            \\
        , .{});
    }

    pub fn run(self: RegistryPurgeCommand, ctx: *router.Context) !void {
        const registry = self.registry orelse if (self.positionals.len >= 1) self.positionals[0] else return error.MissingArgument;
        var derived_name: ?[]const u8 = null;
        var derived_version: ?[]const u8 = null;

        if (self.descriptor) |descriptor| {
            const desc_bytes = try readFile(ctx.allocator, ctx.io, descriptor);
            defer ctx.allocator.free(desc_bytes);
            var parsed = try moonstone.domain.manifest.RemotePackageDescriptor.parse(ctx.allocator, desc_bytes);
            defer parsed.deinit(ctx.allocator);
            derived_name = try ctx.allocator.dupe(u8, parsed.package.name);
            derived_version = try ctx.allocator.dupe(u8, parsed.package.version);

            for (parsed.artifact) |artifact| {
                if (try artifactPath(ctx.allocator, registry, artifact.url)) |path| {
                    defer ctx.allocator.free(path);
                    try maybeDeleteFile(ctx.io, path);
                }
            }
        }

        if (self.blob) |blob| {
            const blob_bytes = try readFile(ctx.allocator, ctx.io, blob);
            defer ctx.allocator.free(blob_bytes);
            const blob_hash = try hashHexAlloc(ctx.allocator, blob_bytes);
            defer ctx.allocator.free(blob_hash);
            const blob_rel = try blobRelPath(ctx.allocator, blob_hash, fileExt(blob));
            defer ctx.allocator.free(blob_rel);
            const blob_abs = try std.fs.path.join(ctx.allocator, &.{ registry, blob_rel });
            defer ctx.allocator.free(blob_abs);
            try maybeDeleteFile(ctx.io, blob_abs);
        }

        const p_name = self.p_name orelse derived_name orelse if (self.positionals.len >= 2) self.positionals[1] else return error.MissingArgument;
        const p_version = self.version orelse derived_version orelse if (self.positionals.len >= 3) self.positionals[2] else null;
        const target = if (p_version) |ver| try descriptorPath(ctx.allocator, registry, p_name, ver) else try std.fs.path.join(ctx.allocator, &.{ registry, "packages", p_name });
        defer ctx.allocator.free(target);
        std.Io.Dir.cwd().deleteTree(ctx.io, target) catch |err| if (err != error.FileNotFound) return err;
        try syncRegistry(ctx.allocator, ctx.io, ctx.stdout, registry, "local");
        try ctx.stdout.print("Purged {s}{s}{s} from {s}.\n", .{ p_name, if (p_version != null) "@" else "", p_version orelse "", registry });
    }
};

test "registry authoring suite" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("MOONSTONE_HOME", tmp_path); // Keep cache contained

    var ctx = router.Context{
        .allocator = allocator,
        .io = io,
        .stdout = &aw.writer,
        .stderr = &aw.writer,
        .env = &env_map,
    };

    const registry_path = try std.fs.path.join(allocator, &.{ tmp_path, "test_registry" });
    defer allocator.free(registry_path);

    const create_cmd = RegistryCreateCommand{
        .positionals = &.{registry_path},
    };
    try create_cmd.run(&ctx);

    const index_toml = try std.fs.path.join(allocator, &.{ registry_path, "index.toml" });
    defer allocator.free(index_toml);
    const index_bytes = try readFile(allocator, io, index_toml);
    defer allocator.free(index_bytes);
    try std.testing.expect(index_bytes.len > 0);

    const fake_desc_path = try std.fs.path.join(allocator, &.{ tmp_path, "package.toml" });
    defer allocator.free(fake_desc_path);
    const fake_desc =
        \\[package]
        \\name = "testpkg"
        \\version = "1.0.0"
        \\kind = "lib"
        \\
        \\[[artifact]]
        \\target = "native"
        \\lua_abi = "lua54"
        \\url = "fake_url"
        \\hash = "b3:fakehash"
        \\format = "tar.gz"
        \\bytes = 100
        \\
    ;
    try writeFile(io, fake_desc_path, fake_desc);

    const fake_blob_path = try std.fs.path.join(allocator, &.{ tmp_path, "blob.tar.gz" });
    defer allocator.free(fake_blob_path);
    try writeFile(io, fake_blob_path, "fake_blob_content");

    const push_cmd = RegistryPushCommand{
        .registry = registry_path,
        .descriptor = fake_desc_path,
        .blob = fake_blob_path,
    };
    try push_cmd.run(&ctx);

    const sqlite_zst = try std.fs.path.join(allocator, &.{ registry_path, "index.sqlite.zst" });
    defer allocator.free(sqlite_zst);
    const zst_bytes = try readFile(allocator, io, sqlite_zst);
    defer allocator.free(zst_bytes);
    try std.testing.expect(zst_bytes.len > 0);

    const purge_cmd = RegistryPurgeCommand{
        .registry = registry_path,
        .p_name = "testpkg",
        .version = "1.0.0",
    };
    try purge_cmd.run(&ctx);

    const zst_bytes_after = try readFile(allocator, io, sqlite_zst);
    defer allocator.free(zst_bytes_after);
    try std.testing.expect(zst_bytes_after.len != zst_bytes.len);

    // Push it again to be available for add
    try push_cmd.run(&ctx);

    // E2E Client Project Test
    const project_path = try std.fs.path.join(allocator, &.{ tmp_path, "project" });
    defer allocator.free(project_path);
    try mkdirp(io, project_path);

    const init_toml = try std.fs.path.join(allocator, &.{ project_path, "moonstone.toml" });
    defer allocator.free(init_toml);
    try writeFile(io, init_toml,
        \\[project]
        \\name = "test_project"
        \\version = "0.1.0"
        \\
        \\[dependencies]
        \\
    );

    var cwdbuf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwdbuf);

    try std.posix.chdir(project_path);
    defer std.posix.chdir(old_cwd) catch {};

    const RegistryAddCommand = @import("registry.zig").RegistryAddCommand;
    const reg_add_cmd = RegistryAddCommand{
        .name = "myreg",
        .uri = registry_path,
    };
    try reg_add_cmd.run(&ctx);

    const AddCommand = @import("add.zig").add_command;
    const add_cmd = AddCommand{
        .positionals = &.{"myreg:testpkg@1.0.0"},
    };
    try add_cmd.run(&ctx);
}
