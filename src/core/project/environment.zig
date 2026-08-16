const builtin = @import("builtin");

pub fn pathSeparator() u8 {
    return if (builtin.os.tag == .windows) ';' else ':';
}

pub fn luaCmoduleExtensions() []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &.{".dll"},
        // Native Moonstone builds may use .dylib, while LuaRocks builtin
        // modules conventionally retain the portable .so suffix on macOS.
        .macos => &.{ ".dylib", ".so" },
        else => &.{".so"},
    };
}

pub fn nativeLibraryEnvironmentVariable() ?[]const u8 {
    return switch (builtin.os.tag) {
        .linux, .freebsd => "LD_LIBRARY_PATH",
        .macos => "DYLD_FALLBACK_LIBRARY_PATH",
        .windows => null,
        else => null,
    };
}
