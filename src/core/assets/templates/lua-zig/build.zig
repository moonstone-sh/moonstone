const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const native_module = b.createModule(.{
        .root_source_file = b.path("native/src/bridge.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });

    const native = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "{{module_name}}_native",
        .root_module = native_module,
    });

    native.root_module.addIncludePath(b.path(".moonstone/env/include"));
    native.root_module.link_libc = true;
    native.linker_allow_shlib_undefined = true;

    const copy_to_env = b.addSystemCommand(&.{
        "sh",
        "-c",
        "mkdir -p .moonstone/env/lib/lua/{{lua_ver}} && cp \"$1\" .moonstone/env/lib/lua/{{lua_ver}}/{{module_name}}_native.so",
        "sh",
    });
    copy_to_env.addFileArg(native.getEmittedBin());

    const install_native = b.step("install-native", "Build and install the Zig Lua module into .moonstone/env");
    install_native.dependOn(&copy_to_env.step);

    const run = b.addSystemCommand(&.{ "lua", "src/main.lua" });
    run.step.dependOn(&copy_to_env.step);
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "Build the native module and run the Lua app");
    run_step.dependOn(&run.step);
}
