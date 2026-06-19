const std = @import("std");
const meteorite = @import("meteorite.zig");
const bridge = @import("bridge.zig");
const graph = @import("meteorite_graph");
const build_info = @import("build_options");

const LuaRuntime = if (std.mem.eql(u8, build_info.hybrid_profile, "optimized"))
    bridge.CachedHybridRuntime
else
    bridge.HybridLuaRuntime;

const SelectedBackend = if (std.mem.eql(u8, build_info.backend, "fast_http"))
    meteorite.backends.fast_http
else
    meteorite.backends.std_http;

const App = meteorite.compile(.{
    .graph = graph,
    .backend = SelectedBackend,
    .lua_runtime = LuaRuntime,
    .hybrid_profile = build_info.hybrid_profile,
});

pub fn main(init: std.process.Init) !void {
    try App.run(init.io);
}
