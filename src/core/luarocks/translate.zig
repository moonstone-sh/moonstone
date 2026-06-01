const std = @import("std");
const manifest = @import("../domain/manifest.zig");
const rockspec = @import("rockspec.zig");
const Recipe = manifest.Recipe;

pub fn to_recipe(allocator: std.mem.Allocator, rock: rockspec.Rockspec, source_hash: []const u8) !Recipe {
    return Recipe{
        .name = try allocator.dupe(u8, rock.package),
        .version = try allocator.dupe(u8, rock.version),
        .source_hash = try allocator.dupe(u8, source_hash),
        .materializer_kind = try allocator.dupe(u8, "copy_lua"),
        .materializer_version = try allocator.dupe(u8, "v0"),
        .runtime = try allocator.dupe(u8, "lua54"),
        .lua_abi = try allocator.dupe(u8, "lua54"),
        .target = try allocator.dupe(u8, "native"),
    };
}
