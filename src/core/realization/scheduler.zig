const std = @import("std");

/// Bounded, fail-fast execution primitive for accepted realization work.
/// Callers retain task state and use `task_index` to select their request.
/// The scheduler owns worker creation, work claiming, and first-error
/// propagation; it deliberately does not know any resolver or display policy.
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    task_count: usize,
    context: *anyopaque,
    run_task: *const fn (context: *anyopaque, task_index: usize) anyerror!void,
    is_cancelled: ?*const fn (context: *anyopaque) bool = null,

    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    error_mutex: std.Io.Mutex = .init,
    first_error: ?anyerror = null,

    pub fn execute(self: *Scheduler, jobs: usize) !void {
        if (self.task_count == 0) return;
        if (jobs <= 1 or self.task_count == 1) {
            self.worker();
            return self.first_error orelse {};
        }

        const worker_count = @min(jobs, self.task_count);
        var workers: std.Io.Group = .init;
        defer workers.cancel(self.io);
        for (0..worker_count) |worker_index| {
            workers.concurrent(self.io, workerMain, .{self}) catch {
                // Keep the group joined even if resources limit concurrency.
                if (worker_index == 0) self.worker();
                break;
            };
        }
        try workers.await(self.io);

        return self.first_error orelse {};
    }

    fn workerMain(self: *Scheduler) void {
        self.worker();
    }

    fn worker(self: *Scheduler) void {
        while (!self.failed.load(.acquire)) {
            std.Io.checkCancel(self.io) catch |err| {
                self.recordError(err);
                return;
            };
            if (self.is_cancelled) |check| {
                if (check(self.context)) {
                    self.recordError(error.Cancelled);
                    return;
                }
            }
            const task_index = self.next.fetchAdd(1, .monotonic);
            if (task_index >= self.task_count) return;

            self.run_task(self.context, task_index) catch |err| {
                self.recordError(err);
                return;
            };
        }
    }

    fn recordError(self: *Scheduler, err: anyerror) void {
        self.error_mutex.lockUncancelable(self.io);
        defer self.error_mutex.unlock(self.io);
        if (self.first_error == null) self.first_error = err;
        self.failed.store(true, .release);
    }
};

test "scheduler executes every task with one worker" {
    const TestContext = struct {
        count: *std.atomic.Value(usize),

        fn run(context: *anyopaque, _: usize) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.count.fetchAdd(1, .monotonic);
        }
    };

    var count = std.atomic.Value(usize).init(0);
    var context = TestContext{ .count = &count };
    var scheduler = Scheduler{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .task_count = 4,
        .context = @ptrCast(&context),
        .run_task = TestContext.run,
    };
    try scheduler.execute(1);
    try std.testing.expectEqual(@as(usize, 4), count.load(.monotonic));
}

test "scheduler stops issuing work after a task failure" {
    const TestContext = struct {
        count: *std.atomic.Value(usize),

        fn run(context: *anyopaque, task_index: usize) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.count.fetchAdd(1, .monotonic);
            if (task_index == 1) return error.ExpectedFailure;
        }
    };

    var count = std.atomic.Value(usize).init(0);
    var context = TestContext{ .count = &count };
    var scheduler = Scheduler{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .task_count = 4,
        .context = @ptrCast(&context),
        .run_task = TestContext.run,
    };
    try std.testing.expectError(error.ExpectedFailure, scheduler.execute(1));
    try std.testing.expectEqual(@as(usize, 2), count.load(.monotonic));
}

test "cancellation propagates into blocked scheduler workers" {
    const Context = struct {
        io: std.Io,
        started: std.atomic.Value(usize) = .init(0),
        stopped: std.atomic.Value(usize) = .init(0),
        fn run(raw: *anyopaque, _: usize) !void {
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            _ = ctx.started.fetchAdd(1, .release);
            defer _ = ctx.stopped.fetchAdd(1, .release);
            try std.Io.sleep(ctx.io, std.Io.Duration.fromSeconds(60), .awake);
        }
        fn execute(scheduler: *Scheduler) !void {
            try scheduler.execute(2);
        }
    };
    var ctx = Context{ .io = std.testing.io };
    var scheduler = Scheduler{ .allocator = std.testing.allocator, .io = std.testing.io, .task_count = 2, .context = &ctx, .run_task = Context.run };
    var task = try std.Io.concurrent(std.testing.io, Context.execute, .{&scheduler});
    while (ctx.started.load(.acquire) < 2) try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    try std.testing.expectError(error.Canceled, task.cancel(std.testing.io));
    try std.testing.expectEqual(@as(usize, 2), ctx.stopped.load(.acquire));
}
