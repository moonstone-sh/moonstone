const std = @import("std");
const builtin = @import("builtin");

/// Owns only the argv slice used to add a Windows command-shell prefix. The
/// argument strings remain borrowed from the caller.
pub const PreparedArgv = struct {
    argv: []const []const u8,
    owned: ?[][]const u8 = null,

    pub fn deinit(self: *PreparedArgv, allocator: std.mem.Allocator) void {
        if (self.owned) |items| allocator.free(items);
        self.* = undefined;
    }
};

/// Keep command scripts intact: std.process uses its dedicated cmd.exe
/// serializer for .cmd/.bat files, including the outer quote pair required
/// when the executable path contains spaces. Wrapping them as ordinary cmd.exe
/// argv loses that script-specific quoting and escaping.
pub fn prepareArgv(_: std.mem.Allocator, argv: []const []const u8) !PreparedArgv {
    return .{ .argv = argv };
}

test "Windows command scripts retain argv for the script-specific serializer" {
    const original = [_][]const u8{ "C:\\project with spaces\\check.CMD", "first argument", "second" };
    var prepared = try prepareArgv(std.testing.allocator, &original);
    defer prepared.deinit(std.testing.allocator);
    try std.testing.expect(prepared.owned == null);
    try std.testing.expectEqualSlices([]const u8, &original, prepared.argv);
}

test "Windows command launcher executes from a path with spaces" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "launcher with spaces.cmd", .data = "@echo off\r\necho [%~1]\r\n" });
    const script = try tmp.dir.realPathFileAlloc(std.testing.io, "launcher with spaces.cmd", std.testing.allocator);
    defer std.testing.allocator.free(script);
    var prepared = try prepareArgv(std.testing.allocator, &.{ script, "hello world" });
    defer prepared.deinit(std.testing.allocator);
    const result = try run(std.testing.allocator, std.testing.io, .{ .argv = prepared.argv });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("[hello world]", std.mem.trim(u8, result.stdout, "\r\n "));
}

const windows = struct {
    extern "c" fn moonstone_job_create() ?*anyopaque;
    extern "c" fn moonstone_job_assign(job: *anyopaque, process: *anyopaque) c_int;
    extern "c" fn moonstone_thread_resume(thread: *anyopaque) c_int;
    extern "c" fn moonstone_job_close(job: *anyopaque) void;
    extern "c" fn moonstone_process_alive(pid: u32) c_int;
};

pub const OwnedChild = struct {
    child: std.process.Child,
    job: ?*anyopaque = null,

    pub fn wait(self: *OwnedChild, io: std.Io) !std.process.Child.Term {
        return self.child.wait(io);
    }
};

/// Spawn into a private process group or a kill-on-close Windows job. Windows
/// starts suspended so descendants cannot escape before job assignment.
pub fn spawnOwned(io: std.Io, options: std.process.SpawnOptions) !OwnedChild {
    var owned = options;
    if (comptime builtin.os.tag == .windows) {
        const job = windows.moonstone_job_create() orelse return error.ProcessJobCreationFailed;
        errdefer windows.moonstone_job_close(job);
        owned.start_suspended = true;
        var child = try std.process.spawn(io, owned);
        errdefer child.kill(io);
        if (windows.moonstone_job_assign(job, child.id.?) == 0) return error.ProcessJobAssignmentFailed;
        if (!options.start_suspended and windows.moonstone_thread_resume(child.thread_handle) == 0)
            return error.ProcessResumeFailed;
        return .{ .child = child, .job = job };
    }
    if (comptime builtin.os.tag != .wasi) owned.pgid = 0;
    return .{ .child = try std.process.spawn(io, owned) };
}

pub fn killTree(owner: *OwnedChild, io: std.Io) void {
    if (comptime builtin.os.tag == .windows) {
        if (owner.job) |job| windows.moonstone_job_close(job);
        owner.job = null;
    } else if (comptime builtin.os.tag != .wasi) {
        if (owner.child.id) |pid| std.posix.kill(-pid, .KILL) catch {};
    }
    owner.child.kill(io);
}

/// Like std.process.run, with owned build-process cleanup on every error path.
pub fn run(gpa: std.mem.Allocator, io: std.Io, options: std.process.RunOptions) anyerror!std.process.RunResult {
    var child = try spawnOwned(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .expand_arg0 = options.expand_arg0,
        .progress_node = options.progress_node,
        .create_no_window = options.create_no_window,
        .disable_aslr = options.disable_aslr,

        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer killTree(&child, io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ child.child.stdout.?, child.child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (multi_reader.fill(options.reserve_amount, options.timeout)) |_| {
        if (options.stdout_limit.toInt()) |limit| {
            if (stdout_reader.buffered().len > limit)
                return error.StreamTooLong;
        }
        if (options.stderr_limit.toInt()) |limit| {
            if (stderr_reader.buffered().len > limit)
                return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();

    const term = try child.wait(io);

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer gpa.free(stdout_slice);

    const stderr_slice = try multi_reader.toOwnedSlice(1);
    errdefer gpa.free(stderr_slice);

    return .{
        .stdout = stdout_slice,
        .stderr = stderr_slice,
        .term = term,
    };
}

test "canceling a build kills shell descendants and releases capture pipes" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const Context = struct {
        marker: []const u8,
        fn execute(ctx: *@This()) !void {
            const result = try run(std.testing.allocator, std.testing.io, .{
                .argv = &.{ "sh", "-c", "sleep 60 & echo $! > \"$1\"; wait", "cancel-test", ctx.marker },
            });
            defer std.testing.allocator.free(result.stdout);
            defer std.testing.allocator.free(result.stderr);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const marker = try std.fs.path.join(std.testing.allocator, &.{ dir, "child-pid" });
    defer std.testing.allocator.free(marker);
    var ctx = Context{ .marker = marker };
    var task = try std.Io.concurrent(std.testing.io, Context.execute, .{&ctx});
    defer _ = task.cancel(std.testing.io) catch {};
    var pid: ?std.posix.pid_t = null;
    for (0..5000) |_| {
        if (tmp.dir.readFileAlloc(std.testing.io, "child-pid", std.testing.allocator, .limited(64))) |contents| {
            defer std.testing.allocator.free(contents);
            pid = std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, contents, "\r\n "), 10) catch null;
            if (pid != null) break;
        } else |_| {}
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(pid != null);
    try std.testing.expectError(error.Canceled, task.cancel(std.testing.io));
    for (0..1000) |_| {
        std.posix.kill(pid.?, @enumFromInt(0)) catch |err| {
            if (err == error.ProcessNotFound) return;
            return err;
        };
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    }
    return error.DescendantSurvivedCancellation;
}

test "Windows cancellation kills descendants holding capture pipes" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const Context = struct {
        marker: []const u8,
        fn execute(ctx: *@This()) !void {
            const escaped = try std.mem.replaceOwned(u8, std.testing.allocator, ctx.marker, "'", "''");
            defer std.testing.allocator.free(escaped);
            const script = try std.fmt.allocPrint(std.testing.allocator, "$p = Start-Process powershell.exe -ArgumentList '-NoProfile -Command Start-Sleep 60' -NoNewWindow -PassThru; [IO.File]::WriteAllText('{s}', [string]$p.Id); Start-Sleep 60", .{escaped});
            defer std.testing.allocator.free(script);
            const result = try run(std.testing.allocator, std.testing.io, .{
                .argv = &.{ "powershell.exe", "-NoProfile", "-Command", script },
            });
            defer std.testing.allocator.free(result.stdout);
            defer std.testing.allocator.free(result.stderr);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const marker = try std.fs.path.join(std.testing.allocator, &.{ dir, "child-pid" });
    defer std.testing.allocator.free(marker);
    var ctx = Context{ .marker = marker };
    var task = try std.Io.concurrent(std.testing.io, Context.execute, .{&ctx});
    defer _ = task.cancel(std.testing.io) catch {};
    var pid: ?u32 = null;
    for (0..10000) |_| {
        if (tmp.dir.readFileAlloc(std.testing.io, "child-pid", std.testing.allocator, .limited(64))) |contents| {
            defer std.testing.allocator.free(contents);
            pid = std.fmt.parseInt(u32, std.mem.trim(u8, contents, "\r\n "), 10) catch null;
            if (pid != null) break;
        } else |_| {}
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(pid != null);
    try std.testing.expectError(error.Canceled, task.cancel(std.testing.io));
    for (0..1000) |_| {
        if (windows.moonstone_process_alive(pid.?) == 0) return;
        try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    }
    return error.DescendantSurvivedCancellation;
}
