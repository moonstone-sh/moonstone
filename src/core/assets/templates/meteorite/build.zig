const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.option([]const u8, "mode", "Meteorite build mode") orelse "hybrid";
    const graph_input = b.option([]const u8, "graph-input", "Meteorite app entry Lua file") orelse "src/main.lua";
    const graph_output = b.option([]const u8, "graph-output", "Generated Meteorite graph directory") orelse ".meteorite/graph/current";
    const lua_root = b.option([]const u8, "lua-root", "Lua runtime root with include/ and lib/") orelse ".moonstone/env/libexec/lua/files";
    const hybrid_profile = b.option([]const u8, "hybrid-profile", "Hybrid profile") orelse "default";
    const backend = b.option([]const u8, "backend", "HTTP backend: std_http or fast_http") orelse "std_http";
    const fast_http_strategy = b.option([]const u8, "fast-http-strategy", "fast_http strategy: threaded_probe or pool") orelse "threaded_probe";
    const fast_http_workers = b.option(u16, "fast-http-workers", "fast_http pool worker count; 0 means CPU count") orelse 0;
    const fast_http_queue = b.option(u16, "fast-http-queue", "fast_http pool queue limit") orelse 1024;
    if (!std.mem.eql(u8, backend, "std_http") and !std.mem.eql(u8, backend, "fast_http")) {
        std.debug.panic("unsupported -Dbackend={s}; expected std_http or fast_http", .{backend});
    }
    if (!std.mem.eql(u8, fast_http_strategy, "threaded_probe") and !std.mem.eql(u8, fast_http_strategy, "pool")) {
        std.debug.panic("unsupported -Dfast-http-strategy={s}; expected threaded_probe or pool", .{fast_http_strategy});
    }
    const router_dispatch = b.option([]const u8, "router-dispatch", "Router dispatch strategy: method_buckets, static_fast_path, param_matchers, or legacy_scan") orelse "method_buckets";
    if (!std.mem.eql(u8, router_dispatch, "method_buckets") and !std.mem.eql(u8, router_dispatch, "static_fast_path") and !std.mem.eql(u8, router_dispatch, "param_matchers") and !std.mem.eql(u8, router_dispatch, "legacy_scan")) {
        std.debug.panic("unsupported -Drouter-dispatch={s}; expected method_buckets, static_fast_path, param_matchers, or legacy_scan", .{router_dispatch});
    }
    const optimize: std.builtin.OptimizeMode = if (std.mem.startsWith(u8, mode, "release-"))
        .ReleaseFast
    else
        b.standardOptimizeOption(.{});
    const lua_runtime = !std.mem.eql(u8, mode, "release-static");
    const lua_state_strategy = if (lua_runtime and std.mem.eql(u8, hybrid_profile, "optimized")) "per_thread_cached_refs" else if (lua_runtime) "per_request_state" else "none";

    const meteorite_root = ".moonstone/env/libexec/meteorite";
    const graph_step = b.addSystemCommand(&.{ ".moonstone/env/bin/lua", meteorite_root ++ "/src/meteorite/cli.lua", "graph", graph_input, graph_output, mode });

    const build_info_content = std.fmt.allocPrint(b.allocator,
        \\const builtin = @import("builtin");
        \\
        \\pub const meteorite_mode = "{s}";
        \\pub const backend = "{s}";
        \\pub const fast_http_strategy = "{s}";
        \\pub const fast_http_workers = {};
        \\pub const fast_http_queue = {};
        \\pub const lua_runtime = {};
        \\pub const hybrid_profile = "{s}";
        \\pub const lua_state_strategy = "{s}";
        \\pub const router_dispatch = "{s}";
        \\
        \\pub const zig_optimize = @tagName(builtin.mode);
        \\pub const cpu_arch = @tagName(builtin.cpu.arch);
        \\pub const os_tag = @tagName(builtin.os.tag);
        \\pub const abi = @tagName(builtin.abi);
        \\pub const target = cpu_arch ++ "-" ++ os_tag ++ "-" ++ abi;
        \\
    , .{ mode, backend, fast_http_strategy, fast_http_workers, fast_http_queue, lua_runtime, hybrid_profile, lua_state_strategy, router_dispatch }) catch @panic("OOM");
    const write_build_info = b.addWriteFiles();
    const build_info_file = write_build_info.add(std.fs.path.join(b.allocator, &.{ graph_output, "build_info.zig" }) catch @panic("OOM"), build_info_content);
    graph_step.step.dependOn(&write_build_info.step);

    const pattern_module = b.createModule(.{
        .root_source_file = b.path(meteorite_root ++ "/native/src/pattern.zig"),
        .target = target,
        .optimize = optimize,
    });
    const build_info_module = b.createModule(.{
        .root_source_file = build_info_file,
        .target = target,
        .optimize = optimize,
    });
    const graph_module = b.createModule(.{
        .root_source_file = b.path(std.fs.path.join(b.allocator, &.{ graph_output, "graph.zig" }) catch @panic("OOM")),
        .target = target,
        .optimize = optimize,
    });
    const ctx_module = b.createModule(.{
        .root_source_file = b.path(std.fs.path.join(b.allocator, &.{ graph_output, "ctx.zig" }) catch @panic("OOM")),
        .target = target,
        .optimize = optimize,
    });
    graph_module.addImport("meteorite_ctx", ctx_module);
    graph_module.addImport("meteorite_pattern", pattern_module);

    const handlers_module = b.createModule(.{
        .root_source_file = b.path("native/src/handlers.zig"),
        .target = target,
        .optimize = optimize,
    });
    handlers_module.addImport("meteorite_graph", ctx_module);
    handlers_module.addImport("meteorite_build_info", build_info_module);
    const validators_module = b.createModule(.{
        .root_source_file = b.path("native/src/validators.zig"),
        .target = target,
        .optimize = optimize,
    });
    const meteorite_module = b.createModule(.{
        .root_source_file = b.path(meteorite_root ++ "/native/src/meteorite.zig"),
        .target = target,
        .optimize = optimize,
    });
    meteorite_module.addImport("build_options", build_info_module);
    meteorite_module.addImport("meteorite_pattern", pattern_module);
    const bridge_module = b.createModule(.{
        .root_source_file = b.path(meteorite_root ++ "/native/src/bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    bridge_module.addIncludePath(b.path(std.fs.path.join(b.allocator, &.{ lua_root, "include" }) catch @panic("OOM")));
    bridge_module.addLibraryPath(b.path(std.fs.path.join(b.allocator, &.{ lua_root, "lib" }) catch @panic("OOM")));
    bridge_module.linkSystemLibrary("lua", .{});
    bridge_module.linkSystemLibrary("m", .{});
    bridge_module.addImport("meteorite_graph", graph_module);

    graph_module.addImport("meteorite_handlers", handlers_module);
    graph_module.addImport("meteorite_validators", validators_module);
    graph_module.addImport("meteorite.zig", meteorite_module);

    const exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("native/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "meteorite_graph", .module = graph_module },
                .{ .name = "meteorite.zig", .module = meteorite_module },
                .{ .name = "bridge.zig", .module = bridge_module },
                .{ .name = "build_options", .module = build_info_module },
                .{ .name = "meteorite_pattern", .module = pattern_module },
            },
        }),
    });
    exe.step.dependOn(&graph_step.step);

    const install_server = b.addSystemCommand(&.{ "sh", "-c", "mkdir -p dist && cp \"$1\" \"${2:-dist/server}\"", "sh" });
    install_server.addFileArg(exe.getEmittedBin());
    if (b.args) |args| {
        if (args.len > 0) install_server.addArg(args[0]) else install_server.addArg("dist/server");
    } else {
        install_server.addArg("dist/server");
    }
    install_server.step.dependOn(&exe.step);

    const install_step = b.step("install-server", "Build the Meteorite HTTP server into dist/server");
    install_step.dependOn(&install_server.step);

    const default_step = b.getInstallStep();
    default_step.dependOn(install_step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(&graph_step.step);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Build and run the Meteorite HTTP server");
    run_step.dependOn(&run.step);
}
