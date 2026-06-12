const std = @import("std");

pub const domain = struct {
    pub const manifest = @import("domain/manifest.zig");
    pub const semver = @import("domain/semver.zig");
    pub const lockfile = @import("domain/lockfile.zig");
    pub const package_spec = @import("domain/package_spec.zig");
};

pub const identity = struct {
    pub const hash = @import("identity/hash.zig");
};

pub const diagnostics = struct {
    pub const profiler = @import("diagnostics/profiler.zig");
};

pub const platform = struct {
    pub const fs = @import("platform/fs.zig");
    pub const env = @import("platform/env.zig");
    pub const fetcher = @import("platform/fetcher.zig");
    pub const http = @import("platform/http.zig");
};

pub const store = struct {
    pub const driver = @import("store/driver.zig");
    pub const artifacts = @import("store/artifacts.zig");
    pub const links = @import("store/links.zig");
    pub const facade = @import("store.zig");
};

pub const registry = struct {
    pub const core = @import("registry/registry.zig");
    pub const resolver = @import("registry/registry_resolver.zig");
};

pub const luarocks = struct {
    pub const rockspec = @import("luarocks/rockspec.zig");
    pub const translate = @import("luarocks/translate.zig");
};

pub const resolution = @import("resolution/root.zig");

pub const materialization = struct {
    pub const materializer = @import("materialization/materializer.zig");
    pub const materializers = struct {
        pub const cmake = @import("materialization/materializers/cmake.zig");
        pub const copy_lua = @import("materialization/materializers/copy_lua.zig");
        pub const unpack_binary = @import("materialization/materializers/unpack_binary.zig");
        pub const command = @import("materialization/materializers/command.zig");
        pub const native_cmodule = @import("materialization/materializers/native_cmodule.zig");
    };
};

pub const project = struct {
    pub const linker = @import("project/linker.zig");
    pub const run_env = @import("project/run_env.zig");
    pub const tool_lua = @import("project/tool_lua.zig");
    pub const discovery = @import("project/discovery.zig");
};

pub const assets = struct {
    pub const bridge_lua = @embedFile("luarocks/bridge.lua");
    
    pub const raw = struct {
        pub const gitignore = @embedFile("assets/gitignore.template");

        pub const templates = struct {
            pub const script_main = @embedFile("assets/templates/script/main.lua");
            pub const lib_lua = @embedFile("assets/templates/lib/lib.lua");
            pub const nvim_init = @embedFile("assets/templates/nvim/init.lua");
            pub const nvim_config = @embedFile("assets/templates/nvim/config.lua");
            pub const nvim_plugin = @embedFile("assets/templates/nvim/plugin.lua");
            pub const nvim_luarc = @embedFile("assets/templates/nvim/luarc.json");
            pub const love_main = @embedFile("assets/templates/love/main.lua");
            pub const love_conf = @embedFile("assets/templates/love/conf.lua");
            pub const love_partiture = @embedFile("assets/templates/love/partiture.lua");
            pub const love_luarc = @embedFile("assets/templates/love/luarc.json");
            pub const c_bin_main = @embedFile("assets/templates/c-bin/main.c");
            pub const c_bin_makefile = @embedFile("assets/templates/c-bin/Makefile");
            pub const zig_bin_main = @embedFile("assets/templates/zig-bin/main.zig");
            pub const zig_bin_build = @embedFile("assets/templates/zig-bin/build.zig");
            pub const rust_bin_main = @embedFile("assets/templates/rust-bin/main.rs");
            pub const rust_bin_cargo = @embedFile("assets/templates/rust-bin/Cargo.toml");
            pub const bin_main = @embedFile("assets/templates/bin/main.c");
            pub const generic_luarc = @embedFile("assets/templates/generic_luarc.json");
        };

        pub const shells = struct {
            pub const posix = @embedFile("assets/shells/posix.sh");
            pub const fish = @embedFile("assets/shells/fish.fish");
        };
    };
};

test {
    std.testing.refAllDecls(@This());
}
