const std = @import("std");
const builtin = @import("builtin");

// ────────────────────────────────────────────────────────────────────────────
//  Signal handling for cooperative cancellation
// ────────────────────────────────────────────────────────────────────────────

/// Global pointer to the active cancellation flag.  Only one
/// `runWithProgress` call is active at a time (it runs on the main
/// thread), so a single global is safe.
var global_cancel: ?*std.atomic.Value(bool) = null;

fn sigintHandler(sig: std.c.SIG) callconv(.c) void {
    _ = sig;
    if (global_cancel) |c| c.store(true, .release);
}

/// Installs SIGINT/SIGTERM handlers that set the cancel flag.
/// Returns the previous sigaction so it can be restored on exit.
fn installCancelHandler(cancel: *std.atomic.Value(bool)) ?std.c.Sigaction {
    if (builtin.os.tag == .wasi or builtin.os.tag == .freestanding) return null;

    global_cancel = cancel;

    const act = std.c.Sigaction{
        .handler = .{ .handler = &sigintHandler },
        .mask = std.mem.zeroes(std.c.sigset_t),
        .flags = 0,
    };

    // Use the C library sigaction which returns -1 on error instead of
    // panicking.  In sandboxed environments sigaction may return EPERM.
    var old_int: std.c.Sigaction = undefined;
    if (std.c.sigaction(.INT, &act, &old_int) != 0) {
        global_cancel = null;
        return null;
    }
    var old_term: std.c.Sigaction = undefined;
    if (std.c.sigaction(.TERM, &act, &old_term) != 0) {
        // Restore INT handler and bail.
        _ = std.c.sigaction(.INT, &old_int, null);
        global_cancel = null;
        return null;
    }

    return old_int;
}

fn uninstallCancelHandler(old: ?std.c.Sigaction) void {
    if (builtin.os.tag == .wasi or builtin.os.tag == .freestanding) return;
    if (old) |*o| {
        _ = std.c.sigaction(.INT, o, null);
        _ = std.c.sigaction(.TERM, o, null);
    }
    global_cancel = null;
}

// ────────────────────────────────────────────────────────────────────────────
//  Events
// ────────────────────────────────────────────────────────────────────────────

/// Events sent from worker threads to the UI thread.
///
/// String slices in events must outlive their consumption by the UI thread.
/// In practice they are either compile-time string literals or allocated from
/// the process-level arena (which lives for the entire process), so they are
/// always valid when the UI thread reads them.
pub const ProgressEvent = union(enum) {
    phase_started: []const u8,
    phase_done: []const u8,

    status: struct {
        id: []const u8,
        msg: []const u8,
    },

    package_started: []const u8,
    package_done: []const u8,

    bytes: struct {
        label: []const u8,
        done: u64,
        total: ?u64,
    },

    warning: []const u8,
    done,
    failed: []const u8,
};

// ────────────────────────────────────────────────────────────────────────────
//  Queue — bounded MPSC ring buffer
// ────────────────────────────────────────────────────────────────────────────

/// A bounded, single-producer / single-consumer ring buffer protected by a
/// mutex.  When full, the oldest event is overwritten — progress events are
/// ephemeral; the latest state is what matters.  The terminal events
/// (`.done` / `.failed`) are never lost in practice because they are sent
/// last, after the worker has stopped producing other events.
pub const ProgressQueue = struct {
    items: []ProgressEvent,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    mutex: std.Io.Mutex = .init,
    io: std.Io,

    const default_capacity = 256;

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !ProgressQueue {
        const items = try allocator.alloc(ProgressEvent, default_capacity);
        return .{ .items = items, .io = io };
    }

    pub fn deinit(self: *ProgressQueue, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }

    pub fn send(self: *ProgressQueue, event: ProgressEvent) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.items[self.head] = event;
        self.head = (self.head + 1) % self.items.len;
        if (self.count < self.items.len) {
            self.count += 1;
        } else {
            self.tail = (self.tail + 1) % self.items.len;
        }
    }

    pub fn tryRecv(self: *ProgressQueue) ?ProgressEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.count == 0) return null;
        const event = self.items[self.tail];
        self.tail = (self.tail + 1) % self.items.len;
        self.count -= 1;
        return event;
    }
};

// ────────────────────────────────────────────────────────────────────────────
//  Worker context
// ────────────────────────────────────────────────────────────────────────────

/// Passed to the worker function.  Contains everything the worker needs to
/// communicate with the UI thread and check for cancellation.
pub const WorkerContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    queue: *ProgressQueue,
    cancel: *std.atomic.Value(bool),
    /// Opaque pointer to command-specific data (flags, parsed manifest, etc.)
    cmd_data: ?*anyopaque = null,
    /// Set by the worker on failure so the main thread can propagate the error.
    err: ?anyerror = null,
    /// Set by the worker for structured error reporting.
    pub fn isCancelled(self: *const WorkerContext) bool {
        return self.cancel.load(.acquire);
    }

    pub fn send(self: *WorkerContext, event: ProgressEvent) void {
        self.queue.send(event);
    }

    pub fn sendPhase(self: *WorkerContext, msg: []const u8) void {
        self.send(.{ .phase_started = msg });
    }

    pub fn sendPhaseDone(self: *WorkerContext, msg: []const u8) void {
        self.send(.{ .phase_done = msg });
    }

    pub fn sendPackageStarted(self: *WorkerContext, name: []const u8) void {
        self.send(.{ .package_started = name });
    }

    pub fn sendPackageDone(self: *WorkerContext, name: []const u8) void {
        self.send(.{ .package_done = name });
    }

    pub fn sendBytesBorrowedUnsafe(self: *WorkerContext, label: []const u8, done: u64, total: ?u64) void {
        self.send(.{ .bytes = .{ .label = label, .done = done, .total = total } });
    }

    pub fn sendBytesOwned(
        self: *WorkerContext,
        label: []const u8,
        done: u64,
        total: ?u64,
    ) void {
        const stable_label = self.allocator.dupe(u8, label) catch return;
        self.send(.{
            .bytes = .{
                .label = stable_label,
                .done = done,
                .total = total,
            },
        });
    }

    pub fn sendStatus(self: *WorkerContext, id: []const u8, msg: []const u8) void {
        const id_copy = self.allocator.dupe(u8, id) catch return;
        const msg_copy = self.allocator.dupe(u8, msg) catch return;

        self.send(.{
            .status = .{
                .id = id_copy,
                .msg = msg_copy,
            },
        });
    }

    pub fn sendWarning(self: *WorkerContext, msg: []const u8) void {
        const msg_copy = self.allocator.dupe(u8, msg) catch return;
        self.send(.{ .warning = msg_copy });
    }
};

// ────────────────────────────────────────────────────────────────────────────
//  UI — Docker-style braille spinner + filling progress bar
// ────────────────────────────────────────────────────────────────────────────

const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const fill_levels = [_][]const u8{ "⠀", "⡀", "⣀", "⣄", "⣤", "⣦", "⣶", "⣷", "⣿" };

pub const ProgressUi = struct {
    writer: *std.Io.Writer,
    output_fd: std.posix.fd_t,
    is_tty: bool,
    io: std.Io,

    // render state
    spinner_frame: usize = 0,
    current_phase: []const u8 = "",
    current_package: ?[]const u8 = null,
    dl_label: []const u8 = "",
    dl_done: u64 = 0,
    dl_total: ?u64 = null,
    last_render_ns: i128 = 0,

    // cancellation state
    stopping: bool = false,
    stopped_count: usize = 0,
    stop_total: usize = 0,

    // track previous line length for space-padding
    last_line_len: usize = 0,

    // accumulated warnings to print at the end
    warnings: std.ArrayList([]const u8),

    const render_interval_ns: i128 = 16 * std.time.ns_per_ms; // ~60 fps

    pub fn init(
        writer: *std.Io.Writer,
        output_fd: std.posix.fd_t,
        is_tty: bool,
        io: std.Io,
    ) ProgressUi {
        return .{
            .writer = writer,
            .output_fd = output_fd,
            .is_tty = is_tty,
            .io = io,
            .warnings = .empty,
        };
    }

    pub fn deinit(self: *ProgressUi) void {
        self.warnings.deinit(std.heap.page_allocator);
    }

    /// Write directly to stdout fd, bypassing the buffered Threaded I/O writer.
    /// This ensures spinner frames are written atomically so carriage-return
    /// actually returns the cursor to column 0 instead of being split across writes.
    fn rawWrite(self: *ProgressUi, data: []const u8) void {
        if (builtin.os.tag == .wasi or builtin.os.tag == .freestanding) {
            self.writer.writeAll(data) catch {};
            self.writer.flush() catch {};
            return;
        }

        var file = std.Io.File{
            .handle = self.output_fd,
            .flags = .{ .nonblocking = false },
        };

        file.writeStreamingAll(self.io, data) catch {};
    }

    pub fn apply(self: *ProgressUi, event: ProgressEvent) void {
        switch (event) {
            .phase_started => |msg| {
                self.current_phase = msg;
                self.current_package = null;
                self.dl_done = 0;
                self.dl_total = null;
                if (!self.is_tty) {
                    self.writer.print("{s}\n", .{msg}) catch {};
                    self.writer.flush() catch {};
                }
            },
            .phase_done => |msg| {
                self.current_phase = "";
                self.current_package = null;
                self.dl_label = "";
                self.dl_done = 0;
                self.dl_total = null;

                if (self.is_tty) {
                    self.rawWrite("\x1b[2K\r");
                    self.writer.print("⠿ {s}\n", .{msg}) catch {};
                } else {
                    self.writer.print("{s}\n", .{msg}) catch {};
                }
                self.writer.flush() catch {};
            },
            .package_started => |name| {
                self.current_package = name;
                if (!self.is_tty) {
                    self.writer.print("  → {s}\n", .{name}) catch {};
                    self.writer.flush() catch {};
                }
            },
            .package_done => |name| {
                if (self.current_package) |cp| {
                    if (std.mem.eql(u8, cp, name)) self.current_package = null;
                }
                // During stopping phase, count completed workers.
                if (self.stopping) self.stopped_count += 1;
            },
            .bytes => |b| {
                self.dl_label = b.label;
                self.dl_done = b.done;
                self.dl_total = b.total;

                // No print here.
                // The renderer will repaint the same progress bar line.
            },
            .warning => |msg| {
                self.warnings.append(std.heap.page_allocator, msg) catch {};
            },
            .status => |s| {
                _ = s.id;

                self.current_phase = s.msg;

                // Important:
                // Do NOT print volatile status in non-TTY/direct mode.
                // Otherwise CI/non-interactive logs get spammed.
            },
            .done, .failed => {},
        }
    }

    fn nowNs(self: *ProgressUi) i128 {
        const ts = std.Io.Timestamp.now(self.io, .awake);
        return ts.nanoseconds;
    }

    pub fn renderIfDue(self: *ProgressUi) void {
        if (!self.is_tty) return;
        const now = self.nowNs();
        if (now - self.last_render_ns < render_interval_ns) return;
        self.last_render_ns = now;
        self.render();
    }

    pub fn render(self: *ProgressUi) void {
        const frame = spinner_frames[self.spinner_frame % spinner_frames.len];
        self.spinner_frame +%= 1;

        // If we have byte progress, show a filling bar.
        if (!self.stopping and self.dl_total != null) {
            if (self.dl_total.? > 0) {
                const fraction = @as(f32, @floatFromInt(self.dl_done)) / @as(f32, @floatFromInt(self.dl_total.?));
                self.renderBar(frame, fraction, 10);
                return;
            }
        }

        const has_no_visible_work =
            !self.stopping and
            self.current_phase.len == 0 and
            self.current_package == null and
            self.dl_total == null and
            self.dl_done == 0;

        if (has_no_visible_work) return;

        // Otherwise, show a spinner line.
        var buf: [320]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("\x1b[2K\r{s} ", .{frame}) catch return;

        if (self.stopping) {
            // Cancellation phase: show "Stopping… x/y"
            if (self.stop_total > 0) {
                w.print("Stopping… {d}/{d}", .{ self.stopped_count, self.stop_total }) catch {};
            } else {
                w.print("Stopping…", .{}) catch {};
            }
        } else {
            if (self.current_phase.len > 0) {
                w.print("{s}", .{self.current_phase}) catch {};
            }
            if (self.current_package) |pkg| {
                w.print(" → {s}", .{pkg}) catch {};
            }
            if (self.dl_done > 0 and self.dl_total == null) {
                w.print(" ({d} bytes)", .{self.dl_done}) catch {};
            }
        }
        self.rawWrite(w.buffer[0..w.end]);
    }

    fn renderBar(self: *ProgressUi, frame: []const u8, fraction: f32, width: usize) void {
        var buf: [512]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("\x1b[2K\r{s} [", .{frame}) catch return;

        const total_states = width * 8;
        const current_state = @as(usize, @intFromFloat(fraction * @as(f32, @floatFromInt(total_states))));

        for (0..width) |i| {
            const char_state = if (current_state >= (i + 1) * 8)
                8
            else if (current_state <= i * 8)
                0
            else
                current_state - i * 8;
            w.print("{s}", .{fill_levels[char_state]}) catch {};
        }
        w.print("] ", .{}) catch {};
        if (self.dl_label.len > 0) {
            w.print("{s} ", .{self.dl_label}) catch {};
        } else if (self.current_package) |pkg| {
            w.print("{s} ", .{pkg}) catch {};
        }
        w.print("{d}/{d} bytes", .{ self.dl_done, self.dl_total.? }) catch {};
        self.rawWrite(w.buffer[0..w.end]);
    }

    /// Called after the UI loop exits (on `.done` or `.failed`).
    /// Clears the spinner line and prints any accumulated warnings.
    pub fn renderFinal(self: *ProgressUi) void {
        if (self.is_tty) {
            self.rawWrite("\x1b[2K\r");
        }

        for (self.warnings.items) |msg| {
            self.writer.print("⚠ {s}\n", .{msg}) catch {};
        }

        if (self.warnings.items.len > 0) {
            self.writer.flush() catch {};
        }
    }

    /// Begin the stopping phase: switch the spinner to show
    /// "Stopping… x/y" and keep animating.
    pub fn beginStopping(self: *ProgressUi, total: usize) void {
        self.stopping = true;
        self.stop_total = total;
        self.stopped_count = 0;
        self.current_phase = "Stopping…";
        self.current_package = null;
        self.dl_total = null;
    }

    /// A worker has stopped; increment the counter.
    pub fn onWorkerStopped(self: *ProgressUi) void {
        self.stopped_count += 1;
    }

    /// Print the final "Stopped x processes" line.
    pub fn renderStopped(self: *ProgressUi) void {
        const n = self.stopped_count;
        if (self.is_tty) {
            self.writer.print("\x1b[2K\r⠿ Stopped {d} process(es).\n", .{n}) catch {};
        } else {
            self.writer.print("Stopped {d} process(es).\n", .{n}) catch {};
        }
        self.writer.flush() catch {};
    }
};

// ────────────────────────────────────────────────────────────────────────────
//  runWithProgress — the entry point
// ────────────────────────────────────────────────────────────────────────────

/// Spawns a worker thread that executes `work_fn`, then runs the UI loop on
/// the calling (main) thread until the worker signals `.done` or `.failed`.
///
/// Only the main thread writes to `stdout` while the UI is active.
/// The worker communicates state changes exclusively through the event queue.
///
/// `cmd_data` is an opaque pointer passed through to the worker via
/// `WorkerContext.cmd_data`; callers use it to pass command-specific state.
pub const CancellationError = error{Cancelled};

pub fn runWithProgress(
    io: std.Io,
    progress_writer: *std.Io.Writer,
    progress_fd: std.posix.fd_t,
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    work_fn: *const fn (*WorkerContext) anyerror!void,
    cmd_data: ?*anyopaque,
) !void {
    const progress_file = std.Io.File{
        .handle = progress_fd,
        .flags = .{ .nonblocking = false },
    };
    const is_tty = progress_file.isTty(io) catch false;

    var queue = try ProgressQueue.init(allocator, io);
    defer queue.deinit(allocator);

    var cancel = std.atomic.Value(bool).init(false);

    var wctx = WorkerContext{
        .allocator = allocator,
        .io = io,
        .env = env,
        .queue = &queue,
        .cancel = &cancel,
        .cmd_data = cmd_data,
    };

    // Install SIGINT/SIGTERM handlers for cooperative cancellation.
    const old_sa = installCancelHandler(&cancel);
    defer uninstallCancelHandler(old_sa);

    // Spawn worker thread with a larger stack size (8MB) to avoid stack overflows
    // when parsing large structures (like MoonstoneToml) on platforms with small defaults.
    const spawn_config = std.Thread.SpawnConfig{ .stack_size = 8 * 1024 * 1024 };
    const thread = try std.Thread.spawn(spawn_config, workerMain, .{ work_fn, &wctx });
    defer thread.join();

    // Run UI loop on the main thread.
    var ui = ProgressUi.init(progress_writer, progress_fd, is_tty, io);
    defer ui.deinit();

    const poll_sleep = std.Io.Duration.fromMilliseconds(16);
    var cancellation_shown = false;
    while (true) {
        // Drain all pending events.
        while (queue.tryRecv()) |event| {
            ui.apply(event);
            switch (event) {
                .done => {
                    ui.renderFinal();
                    return;
                },
                .failed => {
                    if (cancel.load(.acquire)) {
                        // Worker stopped due to cancellation.
                        ui.onWorkerStopped();
                        ui.renderStopped();
                        return error.Cancelled;
                    }
                    ui.renderFinal();
                    if (wctx.err) |err| return err;
                    return error.WorkerFailed;
                },
                else => {},
            }
        }

        // Detect user cancellation (Ctrl-C / SIGTERM).
        if (cancel.load(.acquire) and !cancellation_shown) {
            cancellation_shown = true;
            ui.beginStopping(0); // total will be updated by events
            if (!is_tty) {
                progress_writer.print("Stopping…\n", .{}) catch {};
                progress_writer.flush() catch {};
            }
        }

        ui.renderIfDue();
        // Sleep ~16ms (cooperative; not a cancelation point for the UI thread).
        std.Io.sleep(io, poll_sleep, .awake) catch {};
    }
}

/// Wrapper that calls the user-provided work function, captures any error,
/// and sends the terminal event.
fn workerMain(work_fn: *const fn (*WorkerContext) anyerror!void, ctx: *WorkerContext) void {
    work_fn(ctx) catch |err| {
        ctx.err = err;
        ctx.queue.send(.{ .failed = @errorName(err) });
        return;
    };
    ctx.queue.send(.done);
}

// ────────────────────────────────────────────────────────────────────────────
//  ProgressBackend — abstracts direct-stdout vs event-queue progress output
// ────────────────────────────────────────────────────────────────────────────

/// Routes progress output either directly to a Writer (for JSON / non-TTY / no
/// progress mode) or through the event queue (for interactive progress mode).
///
/// Worker code calls `phase`, `phaseDone`, `packageStarted`, etc. on this
/// backend without caring where the output goes.
pub const ProgressBackend = union(enum) {
    direct: *std.Io.Writer,
    queue: *WorkerContext,

    pub fn phase(self: ProgressBackend, comptime fmt: []const u8, args: anytype) void {
        switch (self) {
            .direct => |w| {
                w.print(fmt ++ "\n", args) catch {};
                w.flush() catch {};
            },
            .queue => |wctx| {
                var buf: [256]u8 = undefined;
                const tmp = std.fmt.bufPrint(&buf, fmt, args) catch return;
                // Strip trailing newlines — the UI handles line breaks itself.
                const trimmed = std.mem.trimEnd(u8, tmp, "\n");
                // Dupe from the process arena so the string outlives the
                // worker thread's stack frame.
                const msg = wctx.allocator.dupe(u8, trimmed) catch return;
                wctx.sendPhase(msg);
            },
        }
    }

    pub fn phaseDone(self: ProgressBackend, comptime fmt: []const u8, args: anytype) void {
        switch (self) {
            .direct => |w| {
                w.print("\x1b[2K\r⠿ " ++ fmt ++ "\n", args) catch {};
                w.flush() catch {};
            },
            .queue => |wctx| {
                var buf: [256]u8 = undefined;
                const tmp = std.fmt.bufPrint(&buf, fmt, args) catch return;
                const msg = wctx.allocator.dupe(u8, tmp) catch return;
                wctx.sendPhaseDone(msg);
            },
        }
    }

    pub fn packageStarted(self: ProgressBackend, name: []const u8) void {
        switch (self) {
            .direct => |w| {
                w.print("  → {s}\n", .{name}) catch {};
                w.flush() catch {};
            },
            .queue => |wctx| wctx.sendPackageStarted(name),
        }
    }

    pub fn packageDone(self: ProgressBackend, name: []const u8) void {
        switch (self) {
            .direct => {},
            .queue => |wctx| wctx.sendPackageDone(name),
        }
    }

    pub fn bytes(self: ProgressBackend, label: []const u8, done: u64, total: ?u64) void {
        switch (self) {
            .direct => {},
            .queue => |wctx| wctx.sendBytesOwned(label, done, total),
        }
    }

    pub fn status(
        self: ProgressBackend,
        id: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        switch (self) {
            .direct => {
                // Volatile update. Do not print in non-interactive/direct mode.
                // Later you can add --verbose to show these.
            },

            .queue => |wctx| {
                var buf: [256]u8 = undefined;
                const tmp = std.fmt.bufPrint(&buf, fmt, args) catch return;
                const trimmed = std.mem.trimEnd(u8, tmp, "\n");
                wctx.sendStatus(id, trimmed);
            },
        }
    }

    pub fn warning(self: ProgressBackend, comptime fmt: []const u8, args: anytype) void {
        switch (self) {
            .direct => |w| {
                w.print("⚠ " ++ fmt ++ "\n", args) catch {};
                w.flush() catch {};
            },
            .queue => |wctx| {
                var buf: [256]u8 = undefined;
                const tmp = std.fmt.bufPrint(&buf, fmt, args) catch return;
                const msg = wctx.allocator.dupe(u8, tmp) catch return;
                wctx.sendWarning(msg);
            },
        }
    }
};

// ────────────────────────────────────────────────────────────────────────────
//  Callback adapters — translate core resolver/solver events to queue events
// ────────────────────────────────────────────────────────────────────────────

/// Adapter for `ResolveCallback` that forwards events through the queue.
pub fn onResolveEventProgress(ctx: ?*anyopaque, event: @import("moonstone").resolution.options.ResolveEvent) void {
    const wctx: *WorkerContext = @ptrCast(@alignCast(ctx orelse return));
    switch (event) {
        .retry => |r| {
            var buf: [256]u8 = undefined;
            const tmp = std.fmt.bufPrint(
                &buf,
                "Retrying {s} ({d}/{d})",
                .{ r.url, r.attempt, r.max_retries },
            ) catch return;

            wctx.sendWarning(tmp);
        },

        .status => |s| {
            var buf: [256]u8 = undefined;
            const tmp = std.fmt.bufPrint(
                &buf,
                "{s}: {s}",
                .{ s.pkg_name, s.msg },
            ) catch return;

            wctx.sendStatus("resolver", tmp);
        },

        .download_progress => |dp| {
            wctx.sendBytesOwned(
                dp.pkg_name orelse dp.url,
                dp.downloaded_bytes,
                dp.total_bytes,
            );
        },
    }
}

/// Adapter for `SolverCallback` that forwards events through the queue.
pub fn onSolverEventProgress(ctx: ?*anyopaque, event: @import("moonstone").resolution.solver.report.SolverEvent, data: std.json.Value) void {
    const wctx: *WorkerContext = @ptrCast(@alignCast(ctx orelse return));
    var buf: [256]u8 = undefined;
    if (data == .object) {
        if (data.object.get("package")) |pkg| {
            if (pkg == .string) {
                const tmp = switch (event) {
                    .resolving => std.fmt.bufPrint(&buf, "Solving: choosing version for {s}…", .{pkg.string}) catch return,
                    .propagating => std.fmt.bufPrint(&buf, "Solving: applying constraints for {s}…", .{pkg.string}) catch return,
                    .conflict => std.fmt.bufPrint(&buf, "Solving: conflict on {s}…", .{pkg.string}) catch return,
                    .backtracking => std.fmt.bufPrint(&buf, "Solving: backtracking from {s}…", .{pkg.string}) catch return,
                };
                wctx.sendStatus("solver", tmp);
                return;
            }
        }
    }
    const msg = switch (event) {
        .resolving => "Solving: choosing package version…",
        .propagating => "Solving: applying constraints…",
        .conflict => "Solving: conflict found…",
        .backtracking => "Solving: backtracking…",
    };
    wctx.sendStatus("solver", msg);
}
