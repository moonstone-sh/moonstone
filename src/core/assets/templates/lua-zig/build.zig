const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_module = b.createModule(.{
        .root_source_file = b.path("zig/bridge.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });

    const zig_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "{{module_name}}_zig",
        .root_module = zig_module,
    });

    zig_lib.root_module.addIncludePath(b.path(".moonstone/env/include"));
    zig_lib.root_module.link_libc = true;
    zig_lib.linker_allow_shlib_undefined = true;

    const copy_to_env = b.addSystemCommand(&.{
        "sh",
        "-c",
        "mkdir -p .moonstone/env/lib/lua/{{lua_ver}} && cp \"$1\" .moonstone/env/lib/lua/{{lua_ver}}/{{module_name}}_zig.so",
        "sh",
    });
    copy_to_env.addFileArg(zig_lib.getEmittedBin());

    const install_zig = b.step("install-zig", "Build and install the Zig Lua module into .moonstone/env");
    install_zig.dependOn(&copy_to_env.step);

    const run = b.addSystemCommand(&.{ "lua", "src/main.lua" });
    run.step.dependOn(&copy_to_env.step);
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "Build the Zig module and run the Lua app");
    run_step.dependOn(&run.step);
}
