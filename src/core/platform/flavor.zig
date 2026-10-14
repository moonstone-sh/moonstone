//! Lua flavors and source-module variants.
//!
//! A *flavor* is what Lua source can observe about where it runs: the
//! language family and level (PUC Lua 5.1-5.5, LuaJIT, Luau) and the host
//! operating system and architecture. It deliberately excludes the C ABI:
//! `lua_abi` only matters to native modules, which are already realized per
//! ABI by the store.
//!
//! A package may ship several files for one module, one per flavor, by
//! tagging the file name with `@<tag>` suffixes:
//!
//!     lexer.lua              the fallback (optional)
//!     lexer@lua54.lua        PUC Lua 5.4
//!     lexer@luajit.lua       LuaJIT
//!     lexer@lua51@windows.lua
//!
//! The project linker projects exactly one of them as `lexer.lua`. `@` is used
//! instead of Go's `_` so that existing modules such as `parser_luajit.lua`,
//! which are required by that name, are never reinterpreted, and because
//! `.` would collide with `require`'s dot-to-directory mapping.
//!
//! Selection is by dominance, not by score: a candidate wins only if it is at
//! least as specific as every other matching candidate on each dimension
//! (language, os, arch). `foo@lua54` against `foo@linux` on Lua 5.4/Linux is
//! therefore an error rather than a silent preference.
//!
//! `assets/lua/moonstone/variants.lua` implements the same rule for the
//! runtime searcher and for Quaver; keep both in step (the tests at the end
//! of this file and in `tests/lua/variants_spec.lua` share their cases).

const std = @import("std");
const target_mod = @import("target.zig");

pub const Family = enum {
    lua,
    luajit,
    luau,

    pub fn asString(self: Family) []const u8 {
        return @tagName(self);
    }
};

pub const Flavor = struct {
    family: Family,
    /// Language level as a comparable integer: 51 ... 55. LuaJIT and Luau
    /// report 51, the PUC language they extend.
    level: u8,
    os: []const u8,
    arch: []const u8,

    /// `lua54-aarch64-macos`, `luajit-x86_64-linux`: the value of
    /// `MOONSTONE_TARGET` and the key Quaver builds for.
    pub fn id(self: Flavor, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self.family) {
            .lua => std.fmt.allocPrint(allocator, "lua{d}-{s}-{s}", .{ self.level, self.arch, self.os }),
            else => std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ self.family.asString(), self.arch, self.os }),
        };
    }
};

/// Language level from any spelling Moonstone accepts for an ABI or API:
/// `lua54`, `5.4`, `lua-5.4`, `lua@5.4.7`.
pub fn levelFromAbi(abi: []const u8) ?u8 {
    var digits: [2]u8 = undefined;
    var count: usize = 0;
    for (abi) |ch| {
        if (!std.ascii.isDigit(ch)) continue;
        digits[count] = ch - '0';
        count += 1;
        if (count == 2) break;
    }
    if (count != 2 or digits[0] != 5 or digits[1] > 5) return null;
    return 50 + digits[1];
}

pub fn familyFromRuntime(runtime_name: []const u8) Family {
    if (std.ascii.indexOfIgnoreCase(runtime_name, "luajit") != null) return .luajit;
    if (std.ascii.indexOfIgnoreCase(runtime_name, "luau") != null) return .luau;
    return .lua;
}

/// The flavor of a projected environment. Environments are only projected
/// for the host, so os and arch come from the host target.
pub fn fromRuntime(runtime_name: []const u8, abi: []const u8) Flavor {
    const family = familyFromRuntime(runtime_name);
    return .{
        .family = family,
        .level = if (family == .lua) levelFromAbi(abi) orelse 54 else 51,
        .os = hostOs(),
        .arch = hostArch(),
    };
}

pub fn hostOs() []const u8 {
    return osFromTarget(target_mod.hostTargetLiteral());
}

pub fn hostArch() []const u8 {
    return archFromTarget(target_mod.hostTargetLiteral());
}

/// `aarch64-linux-gnu` -> `linux`; `x86_64-windows-msvc` -> `windows`.
pub fn osFromTarget(target: []const u8) []const u8 {
    var parts = std.mem.splitScalar(u8, target, '-');
    _ = parts.next();
    return parts.next() orelse "unknown";
}

pub fn archFromTarget(target: []const u8) []const u8 {
    var parts = std.mem.splitScalar(u8, target, '-');
    return parts.next() orelse "unknown";
}

pub const language_tags = [_][]const u8{ "lua51", "lua52", "lua53", "lua54", "lua55", "luajit", "luau" };
pub const os_tags = [_][]const u8{ "linux", "macos", "windows", "freebsd" };
pub const arch_tags = [_][]const u8{ "x86_64", "aarch64", "riscv64" };

const Dimension = enum { language, os, arch };

fn dimensionOf(tag: []const u8) ?Dimension {
    for (language_tags) |known| if (std.mem.eql(u8, tag, known)) return .language;
    for (os_tags) |known| if (std.mem.eql(u8, tag, known)) return .os;
    for (arch_tags) |known| if (std.mem.eql(u8, tag, known)) return .arch;
    return null;
}

/// How specifically a file applies to a flavor on each dimension. 0 means
/// untagged; a larger value is more specific. `null` from `match` means the
/// file does not apply at all.
pub const Specificity = struct {
    language: u8 = 0,
    os: u8 = 0,
    arch: u8 = 0,

    fn atLeast(self: Specificity, other: Specificity) bool {
        return self.language >= other.language and self.os >= other.os and self.arch >= other.arch;
    }
};

/// A file name split into module stem, tags and extension.
pub const Variant = struct {
    /// `lexer` for `lexer@lua54.lua`.
    stem: []const u8,
    /// `.lua`; includes the dot. The projected name is `stem ++ ext`.
    ext: []const u8,
    /// `@lua54@linux` as written, without the stem and extension.
    tags: []const u8,

    pub fn projectedNameAlloc(self: Variant, allocator: std.mem.Allocator) ![]const u8 {
        return std.mem.concat(allocator, u8, &.{ self.stem, self.ext });
    }

    pub fn match(self: Variant, flavor: Flavor) ?Specificity {
        var spec = Specificity{};
        var tags = std.mem.splitScalar(u8, self.tags[1..], '@');
        while (tags.next()) |tag| {
            switch (dimensionOf(tag).?) {
                .language => spec.language = languageMatch(tag, flavor) orelse return null,
                .os => {
                    if (!std.mem.eql(u8, tag, flavor.os)) return null;
                    spec.os = 1;
                },
                .arch => {
                    if (!std.mem.eql(u8, tag, flavor.arch)) return null;
                    spec.arch = 1;
                },
            }
        }
        return spec;
    }
};

fn languageMatch(tag: []const u8, flavor: Flavor) ?u8 {
    if (std.mem.eql(u8, tag, "luajit")) return if (flavor.family == .luajit) 2 else null;
    if (std.mem.eql(u8, tag, "luau")) return if (flavor.family == .luau) 2 else null;
    const level = levelFromAbi(tag) orelse return null;
    if (level != flavor.level) return null;
    return switch (flavor.family) {
        .lua => 2,
        // LuaJIT runs Lua 5.1 code, so `@lua51` applies to it; `@luajit`
        // still wins. Luau's syntax and library differ too much to inherit.
        .luajit => 1,
        .luau => null,
    };
}

pub const ParseError = error{InvalidModuleVariant};

/// Recognize a variant file name. Returns null for ordinary files, including
/// names with an `@` whose tags are not all in the vocabulary (so an unrelated
/// `foo@bar.lua` keeps working). Tags must appear in dimension order
/// (language, os, arch) and at most once each: the runtime searcher probes
/// names instead of listing directories, so a file it would never probe,
/// such as `foo@linux@lua54.lua`, is rejected here rather than ignored.
pub fn parse(file_name: []const u8) ParseError!?Variant {
    const ext = std.fs.path.extension(file_name);
    if (ext.len == 0) return null;
    const base = file_name[0 .. file_name.len - ext.len];
    const at = std.mem.indexOfScalar(u8, base, '@') orelse return null;
    if (at == 0) return null;
    const tags = base[at..];

    var iterator = std.mem.splitScalar(u8, tags[1..], '@');
    while (iterator.next()) |tag| {
        if (dimensionOf(tag) == null) return null;
    }
    var previous: ?Dimension = null;
    iterator.reset();
    while (iterator.next()) |tag| {
        const dimension = dimensionOf(tag).?;
        if (previous) |seen| if (@intFromEnum(dimension) <= @intFromEnum(seen)) return error.InvalidModuleVariant;
        previous = dimension;
    }
    return .{ .stem = base[0..at], .ext = ext, .tags = tags };
}

pub const Choice = union(enum) {
    /// Index into the candidate list.
    variant: usize,
    /// The untagged fallback file is the most specific match.
    base,
    /// Nothing applies to this flavor.
    none,
    /// Two candidates are each more specific on a different dimension.
    ambiguous: struct { first: usize, second: ?usize },
};

/// Pick the file to project. `has_base` says whether the untagged
/// `stem.ext` exists; it matches every flavor with zero specificity.
pub fn select(candidates: []const Variant, has_base: bool, flavor: Flavor) Choice {
    var best: ?usize = null;
    var best_spec = Specificity{};
    var have_best = has_base;
    for (candidates, 0..) |candidate, index| {
        const spec = candidate.match(flavor) orelse continue;
        if (!have_best or spec.atLeast(best_spec)) {
            best = index;
            best_spec = spec;
            have_best = true;
        }
    }
    if (!have_best) return .none;

    // The winner must be at least as specific as every other match on every
    // dimension; equal specificity from two files is also ambiguous.
    for (candidates, 0..) |candidate, index| {
        if (best != null and index == best.?) continue;
        const spec = candidate.match(flavor) orelse continue;
        if (!best_spec.atLeast(spec) or std.meta.eql(best_spec, spec)) {
            return .{ .ambiguous = .{ .first = index, .second = best } };
        }
    }
    return if (best) |index| .{ .variant = index } else .base;
}

fn testFlavor(family: Family, level: u8, os: []const u8, arch: []const u8) Flavor {
    return .{ .family = family, .level = level, .os = os, .arch = arch };
}

fn parseAll(comptime names: []const []const u8) ![names.len]Variant {
    var out: [names.len]Variant = undefined;
    inline for (names, 0..) |name, index| out[index] = (try parse(name)).?;
    return out;
}

test "levels from every ABI spelling" {
    try std.testing.expectEqual(@as(?u8, 54), levelFromAbi("lua54"));
    try std.testing.expectEqual(@as(?u8, 54), levelFromAbi("5.4"));
    try std.testing.expectEqual(@as(?u8, 51), levelFromAbi("lua-5.1"));
    try std.testing.expectEqual(@as(?u8, 53), levelFromAbi("lua@5.3.6"));
    try std.testing.expectEqual(@as(?u8, null), levelFromAbi("luajit"));
}

test "flavor ids" {
    const allocator = std.testing.allocator;
    const puc = try testFlavor(.lua, 54, "macos", "aarch64").id(allocator);
    defer allocator.free(puc);
    try std.testing.expectEqualStrings("lua54-aarch64-macos", puc);
    const jit = try testFlavor(.luajit, 51, "linux", "x86_64").id(allocator);
    defer allocator.free(jit);
    try std.testing.expectEqualStrings("luajit-x86_64-linux", jit);
}

test "ordinary names are not variants" {
    try std.testing.expect((try parse("lexer.lua")) == null);
    try std.testing.expect((try parse("parser_luajit.lua")) == null);
    try std.testing.expect((try parse("mail@example.lua")) == null);
    try std.testing.expect((try parse("@lua54.lua")) == null);
    try std.testing.expectError(error.InvalidModuleVariant, parse("lexer@lua53@lua54.lua"));
    try std.testing.expectError(error.InvalidModuleVariant, parse("lexer@linux@lua54.lua"));
}

test "variant parts" {
    const variant = (try parse("lexer@lua51@windows.lua")).?;
    try std.testing.expectEqualStrings("lexer", variant.stem);
    try std.testing.expectEqualStrings(".lua", variant.ext);
    try std.testing.expectEqualStrings("@lua51@windows", variant.tags);
}

test "exact language beats the fallback" {
    const candidates = try parseAll(&.{ "lexer@lua51.lua", "lexer@lua54.lua" });
    const choice = select(&candidates, true, testFlavor(.lua, 54, "linux", "x86_64"));
    try std.testing.expectEqual(@as(usize, 1), choice.variant);
}

test "fallback when no tag applies, none without one" {
    const candidates = try parseAll(&.{"lexer@lua51.lua"});
    const flavor = testFlavor(.lua, 54, "linux", "x86_64");
    try std.testing.expect(select(&candidates, true, flavor) == .base);
    try std.testing.expect(select(&candidates, false, flavor) == .none);
}

test "luajit prefers its own tag over lua51 and accepts lua51 alone" {
    const both = try parseAll(&.{ "lexer@lua51.lua", "lexer@luajit.lua" });
    const jit = testFlavor(.luajit, 51, "linux", "x86_64");
    try std.testing.expectEqual(@as(usize, 1), select(&both, false, jit).variant);
    const only = try parseAll(&.{"lexer@lua51.lua"});
    try std.testing.expectEqual(@as(usize, 0), select(&only, false, jit).variant);
}

test "luau does not inherit lua51" {
    const candidates = try parseAll(&.{"lexer@lua51.lua"});
    try std.testing.expect(select(&candidates, true, testFlavor(.luau, 51, "linux", "x86_64")) == .base);
}

test "more tags on the same dimensions win" {
    const candidates = try parseAll(&.{ "fs@lua54.lua", "fs@lua54@windows.lua" });
    const choice = select(&candidates, false, testFlavor(.lua, 54, "windows", "x86_64"));
    try std.testing.expectEqual(@as(usize, 1), choice.variant);
}

test "specific on different dimensions is ambiguous" {
    const candidates = try parseAll(&.{ "fs@lua54.lua", "fs@linux.lua" });
    const choice = select(&candidates, true, testFlavor(.lua, 54, "linux", "x86_64"));
    try std.testing.expect(choice == .ambiguous);
}

test "variant extension is kept" {
    const variant = (try parse("view@luajit.luax")).?;
    const projected = try variant.projectedNameAlloc(std.testing.allocator);
    defer std.testing.allocator.free(projected);
    try std.testing.expectEqualStrings("view.luax", projected);
}
