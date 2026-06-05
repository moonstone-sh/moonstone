const std = @import("std");

pub const ProjectionPolicy = struct {
    link_lua_modules_to_root: bool,
    link_cmodules_to_root: bool,
    expose_public_bins: bool,
    expose_tool_scope: bool,
    expose_helper_scope: bool,
    metadata_only: bool,
    export_default: bool,
};

pub const DependencyRole = enum {
    runtime,
    dev,
    tool,
    helper,
    peer,
    optional,

    pub fn toString(self: DependencyRole) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(str: []const u8) ?DependencyRole {
        inline for (std.meta.fields(DependencyRole)) |field| {
            if (std.mem.eql(u8, str, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }

    pub fn getProjectionPolicy(self: DependencyRole) ProjectionPolicy {
        return switch (self) {
            .runtime => .{
                .link_lua_modules_to_root = true,
                .link_cmodules_to_root = true,
                .expose_public_bins = true,
                .expose_tool_scope = false,
                .expose_helper_scope = false,
                .metadata_only = false,
                .export_default = true,
            },
            .dev => .{
                .link_lua_modules_to_root = true,
                .link_cmodules_to_root = true,
                .expose_public_bins = true,
                .expose_tool_scope = false,
                .expose_helper_scope = false,
                .metadata_only = false,
                .export_default = false,
            },
            .tool => .{
                .link_lua_modules_to_root = false,
                .link_cmodules_to_root = false,
                .expose_public_bins = false,
                .expose_tool_scope = true,
                .expose_helper_scope = false,
                .metadata_only = false,
                .export_default = false,
            },
            .helper => .{
                .link_lua_modules_to_root = true,
                .link_cmodules_to_root = true,
                .expose_public_bins = false,
                .expose_tool_scope = false,
                .expose_helper_scope = true,
                .metadata_only = false,
                .export_default = true,
            },
            .peer => .{
                .link_lua_modules_to_root = false,
                .link_cmodules_to_root = false,
                .expose_public_bins = false,
                .expose_tool_scope = false,
                .expose_helper_scope = false,
                .metadata_only = true,
                .export_default = false,
            },
            .optional => .{
                .link_lua_modules_to_root = false,
                .link_cmodules_to_root = false,
                .expose_public_bins = false,
                .expose_tool_scope = false,
                .expose_helper_scope = false,
                .metadata_only = true,
                .export_default = false,
            },
        };
    }
};