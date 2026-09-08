// SPDX-License-Identifier: Apache-2.0

//! Per-package root identity for the projected project environment.
//!
//! A project environment is derived state: Lua modules reach
//! `.moonstone/env/share/lua/<abi>` as per-file symlinks, so a package that
//! locates itself with `debug.getinfo(1, "S").source` sees the *link* path
//! inside the consumer's environment, not its real installation root. Any
//! package that owns a sibling non-Lua asset (a native library, a data file, a
//! template) therefore cannot compute that asset's location from the module
//! path alone.
//!
//! Moonstone answers that question directly instead of asking every package
//! author to re-derive it: the project linker records each projected package's
//! real root in `.moonstone/env/env.toml`, and `run_env` exports it as
//! `MOONSTONE_PACKAGE_ROOT_<KEY>` alongside `LUA_PATH`/`LUA_CPATH`.
//!
//! See `docs/PROJECT_ENVIRONMENT.md` for the user-facing contract.

const std = @import("std");

pub const environment_prefix = "MOONSTONE_PACKAGE_ROOT_";

/// How a package's files reach the project environment. This is recorded so a
/// consumer can tell a live working tree from an immutable store payload
/// without inspecting the filesystem.
pub const Projection = enum {
    /// A `path:`/`link:` dependency projected from a developer's working tree.
    live,
    /// A materialized artifact projected from the content-addressed store.
    store,

    pub fn asString(self: Projection) []const u8 {
        return switch (self) {
            .live => "live",
            .store => "store",
        };
    }

    pub fn fromString(value: []const u8) ?Projection {
        if (std.mem.eql(u8, value, "live")) return .live;
        if (std.mem.eql(u8, value, "store")) return .store;
        return null;
    }
};

pub const PackageRoot = struct {
    /// The package's declared coordinate, e.g. `moonstone/ballad`.
    name: []const u8,
    /// The real (symlink-resolved) directory the package's files live in.
    root: []const u8,
    /// The exported environment variable name.
    key: []const u8,
    projection: Projection,

    pub fn deinit(self: PackageRoot, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.root);
        allocator.free(self.key);
    }
};

/// Derive the exported variable name for a package coordinate.
///
/// The mapping is deliberately total and lossy-but-deterministic: every byte
/// outside `A-Z` and `0-9` becomes `_` after ASCII upper-casing, so
/// `moonstone/hydronium-ink` becomes
/// `MOONSTONE_PACKAGE_ROOT_MOONSTONE_HYDRONIUM_INK`. Two distinct coordinates
/// can therefore collapse onto one key; the linker treats that as an explicit
/// conflict rather than silently exporting one of the two roots.
pub fn environmentKey(allocator: std.mem.Allocator, package_name: []const u8) ![]u8 {
    const key = try allocator.alloc(u8, environment_prefix.len + package_name.len);
    errdefer allocator.free(key);
    @memcpy(key[0..environment_prefix.len], environment_prefix);
    for (package_name, 0..) |character, index| {
        const upper = std.ascii.toUpper(character);
        key[environment_prefix.len + index] = if (std.ascii.isAlphanumeric(upper)) upper else '_';
    }
    return key;
}

test "environment keys upper-case and normalize package coordinates" {
    const allocator = std.testing.allocator;

    const scoped = try environmentKey(allocator, "moonstone/hydronium-ink");
    defer allocator.free(scoped);
    try std.testing.expectEqualStrings("MOONSTONE_PACKAGE_ROOT_MOONSTONE_HYDRONIUM_INK", scoped);

    const bare = try environmentKey(allocator, "hydronium-ink");
    defer allocator.free(bare);
    try std.testing.expectEqualStrings("MOONSTONE_PACKAGE_ROOT_HYDRONIUM_INK", bare);

    const dotted = try environmentKey(allocator, "lua.cjson");
    defer allocator.free(dotted);
    try std.testing.expectEqualStrings("MOONSTONE_PACKAGE_ROOT_LUA_CJSON", dotted);
}

test "distinct coordinates can collapse onto one key" {
    const allocator = std.testing.allocator;

    const left = try environmentKey(allocator, "a-b/c");
    defer allocator.free(left);
    const right = try environmentKey(allocator, "a/b-c");
    defer allocator.free(right);

    // Documented behavior: the linker must reject this pair rather than pick
    // a winner. Keep the property visible so the mapping is never assumed
    // injective.
    try std.testing.expectEqualStrings(left, right);
}

test "projection labels round-trip" {
    try std.testing.expectEqual(Projection.live, Projection.fromString(Projection.live.asString()).?);
    try std.testing.expectEqual(Projection.store, Projection.fromString(Projection.store.asString()).?);
    try std.testing.expect(Projection.fromString("symlink") == null);
}
