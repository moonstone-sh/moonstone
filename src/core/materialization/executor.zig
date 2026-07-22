const std = @import("std");
const plan_mod = @import("plan.zig");
const MaterializationPlan = plan_mod.MaterializationPlan;

pub fn validatePlan(plan: MaterializationPlan) !void {
    // 1. Check relative paths and reject path traversal
    for (plan.inputs) |inp| {
        if (std.mem.startsWith(u8, inp.mount_path, "/") or std.mem.indexOf(u8, inp.mount_path, "..") != null) {
            return error.InvalidPlanPath;
        }
    }

    for (plan.steps) |step| {
        if (std.mem.startsWith(u8, step.cwd, "/") or std.mem.indexOf(u8, step.cwd, "..") != null) {
            return error.InvalidPlanPath;
        }
        // Verify tool is declared
        var tool_found = false;
        for (plan.tools) |t| {
            if (std.mem.eql(u8, t.id, step.tool_id)) {
                tool_found = true;
                break;
            }
        }
        if (!tool_found) {
            return error.UndeclaredTool;
        }
    }

    for (plan.outputs) |out_rule| {
        if (std.mem.startsWith(u8, out_rule.from, "/") or std.mem.indexOf(u8, out_rule.from, "..") != null or
            std.mem.startsWith(u8, out_rule.to, "/") or std.mem.indexOf(u8, out_rule.to, "..") != null)
        {
            return error.InvalidPlanPath;
        }
    }
}

pub fn executePlan(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    plan: MaterializationPlan,
    work_dir: []const u8,
    out_dir: []const u8,
) !void {
    try validatePlan(plan);

    // 1. Execute plan steps sequentially
    for (plan.steps) |step| {
        // Resolve tool executable
        var tool_path: ?[]const u8 = null;
        for (plan.tools) |t| {
            if (std.mem.eql(u8, t.id, step.tool_id)) {
                tool_path = t.executable;
                break;
            }
        }
        const exec_cmd = tool_path orelse step.tool_id;

        const step_cwd = if (std.mem.eql(u8, step.cwd, ".") or step.cwd.len == 0)
            work_dir
        else
            try std.fs.path.join(allocator, &.{ work_dir, step.cwd });
        defer if (!std.mem.eql(u8, step.cwd, ".") and step.cwd.len > 0) allocator.free(step_cwd);

        var argv_list = try std.ArrayList([]const u8).initCapacity(allocator, step.argv.len + 1);
        defer argv_list.deinit(allocator);
        try argv_list.append(allocator, exec_cmd);
        for (step.argv) |arg| try argv_list.append(allocator, arg);

        const res = std.process.run(allocator, io, .{
            .argv = argv_list.items,
            .cwd = step_cwd,
        }) catch |err| {
            _ = env;
            return err;
        };
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);

        if (res.term != .exited or res.term.exited != 0) {
            return error.ExecutionStepFailed;
        }
    }

    // 2. Collect declared outputs into out_dir
    for (plan.outputs) |out_rule| {
        const src_abs = try std.fs.path.join(allocator, &.{ work_dir, out_rule.from });
        defer allocator.free(src_abs);

        const dest_abs = try std.fs.path.join(allocator, &.{ out_dir, out_rule.to });
        defer allocator.free(dest_abs);

        if (std.fs.path.dirname(dest_abs)) |parent_dir| {
            try std.Io.Dir.cwd().createDirPath(io, parent_dir);
        }

        switch (out_rule.kind) {
            .copy_file, .lua_module, .lua_cmodule, .executable => {
                const cp_res = try std.process.run(allocator, io, .{
                    .argv = &.{ "cp", src_abs, dest_abs },
                });
                defer allocator.free(cp_res.stdout);
                defer allocator.free(cp_res.stderr);
                if (cp_res.term != .exited or cp_res.term.exited != 0) {
                    return error.OutputMissing;
                }
            },
            .copy_tree => {
                const cp_res = try std.process.run(allocator, io, .{
                    .argv = &.{ "cp", "-r", src_abs, dest_abs },
                });
                defer allocator.free(cp_res.stdout);
                defer allocator.free(cp_res.stderr);
                if (cp_res.term != .exited or cp_res.term.exited != 0) {
                    return error.OutputMissing;
                }
            },
        }
    }
}
