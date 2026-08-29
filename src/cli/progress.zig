const std = @import("std");
const builtin = @import("builtin");

pub fn terminalColumns(io: std.Io, env: *std.process.Environ.Map, use_stderr: bool) usize {
    const fallback = columnsFromEnv(env) orelse 80;
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi or builtin.os.tag == .freestanding) return fallback;

    var winsize: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const file = if (use_stderr) std.Io.File.stderr() else std.Io.File.stdout();
    const result = io.operate(.{ .device_io_control = .{
        .file = file,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &winsize,
    } }) catch return fallback;
    if (result.device_io_control >= 0 and winsize.col > 0) return winsize.col;
    return fallback;
}

fn columnsFromEnv(env: *std.process.Environ.Map) ?usize {
    const raw = env.get("COLUMNS") orelse return null;
    const columns = std.fmt.parseUnsigned(usize, raw, 10) catch return null;
    return if (columns > 1) columns else null;
}

/// Reserves the last terminal cell so a repaint never triggers terminal autowrap.
pub fn appendBounded(writer: *std.Io.Writer, text: []const u8, columns: usize) !void {
    const limit = columns -| 1;
    if (limit == 0) return;
    var cells: usize = 0;
    var scan: usize = 0;
    while (scan < text.len) {
        const cluster = boundedCluster(text, scan);
        cells += cluster.cells;
        scan += cluster.len;
    }
    const truncated = cells > limit;
    const content_limit = if (truncated and limit >= 3) limit - 3 else limit;
    var used: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const cluster = boundedCluster(text, index);
        if (cluster.cells > content_limit -| used) break;
        if (cluster.sanitize) {
            try writer.writeByte(' ');
        } else if (cluster.valid) {
            try writer.writeAll(text[index..][0..cluster.len]);
        } else {
            try writer.writeAll("\u{fffd}");
        }
        used += cluster.cells;
        index += cluster.len;
    }
    if (truncated and limit >= 3) try writer.writeAll("...");
}

/// A terminal-friendly binary byte quantity.  The blank unit for bytes keeps
/// byte, KB, MB, ... values in the same `XXX.X UB` shape.
pub const ByteQuantity = struct {
    whole: u64,
    tenths: u4,
    unit: u8,

    pub fn write(self: ByteQuantity, writer: *std.Io.Writer) !void {
        try writer.print("{d}.{d} {c}B", .{ self.whole, self.tenths, self.unit });
    }
};

/// Formats a byte count using 1024-based units and one decimal place.
///
/// Integer arithmetic preserves the rounding boundary for every `u64` value.
/// If rounding produces 1024.0, promote to the next available unit instead of
/// showing a misleading four-digit mantissa.
pub fn byteQuantity(value: u64) ByteQuantity {
    const units = " KMGTPE";
    var unit_index: usize = 0;
    var scale: u64 = 1;
    while (unit_index + 1 < units.len and value >= scale * 1024) {
        scale *= 1024;
        unit_index += 1;
    }

    var rounded_tenths = (@as(u128, value) * 10 + scale / 2) / scale;
    while (unit_index + 1 < units.len and rounded_tenths >= 10240) {
        scale *= 1024;
        unit_index += 1;
        rounded_tenths = (@as(u128, value) * 10 + scale / 2) / scale;
    }

    return .{
        .whole = @intCast(rounded_tenths / 10),
        .tenths = @intCast(rounded_tenths % 10),
        .unit = units[unit_index],
    };
}

/// Selects a bar before labels are truncated.  At small widths the spinner and
/// useful package text remain, while the bar is omitted entirely.
pub fn barWidthForColumns(columns: usize, normal_width: usize) usize {
    return if (columns >= 100) normal_width * 2 else if (columns >= 60) normal_width else 0;
}

/// Converts a possibly stale or malformed fraction to a bar state without an
/// unchecked float-to-integer conversion.  Download counters may temporarily
/// report more bytes than an advertised total, and a zero total is meaningful
/// "unknown/empty", not a full bar.
pub fn progressStates(fraction: f32, total_states: usize) usize {
    if (!(fraction > 0)) return 0; // also maps NaN to a safe empty bar
    if (fraction >= 1) return total_states;
    return @as(usize, @intFromFloat(fraction * @as(f32, @floatFromInt(total_states))));
}

const BoundedCluster = struct { len: usize, cells: usize, valid: bool, sanitize: bool };

const DecodedCodepoint = struct { len: usize, codepoint: u21, valid: bool };

fn decodeCodepoint(text: []const u8, index: usize) DecodedCodepoint {
    const byte = text[index];
    const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch return .{ .len = 1, .codepoint = 0, .valid = false };
    if (sequence_len > text.len - index) return .{ .len = 1, .codepoint = 0, .valid = false };
    const codepoint = std.unicode.utf8Decode(text[index..][0..sequence_len]) catch return .{ .len = 1, .codepoint = 0, .valid = false };
    return .{ .len = sequence_len, .codepoint = codepoint, .valid = true };
}

/// Return one display cluster, rather than a single code point. In particular,
/// VS16 and ZWJ sequences stay intact: emitting only half an emoji sequence can
/// make a terminal choose a different presentation and invalidate the bound.
fn boundedCluster(text: []const u8, index: usize) BoundedCluster {
    const first = decodeCodepoint(text, index);
    if (!first.valid) return .{ .len = first.len, .cells = 1, .valid = false, .sanitize = false };
    if (isControlCodepoint(first.codepoint) or isClusterExtender(first.codepoint)) {
        return .{ .len = first.len, .cells = 1, .valid = true, .sanitize = true };
    }

    var end = index + first.len;
    var cells = displayWidth(first.codepoint);
    var expects_joined_base = false;
    while (end < text.len) {
        const next = decodeCodepoint(text, end);
        if (!next.valid) break;
        // A control must never be admitted as a joined base or continuation:
        // otherwise a ZWJ immediately before it would make the control part
        // of the emitted cluster and allow terminal escape sequences through.
        if (isControlCodepoint(next.codepoint)) break;
        if (next.codepoint == 0x200d) {
            end += next.len;
            expects_joined_base = true;
            continue;
        }
        if (isClusterExtender(next.codepoint)) {
            // Emoji presentation selectors turn otherwise narrow symbols such
            // as U+2764 HEAVY BLACK HEART into a two-cell glyph.
            if (next.codepoint == 0xfe0f or next.codepoint == 0x20e3 or isEmojiModifier(next.codepoint)) cells = @max(cells, 2);
            end += next.len;
            continue;
        }
        if (!expects_joined_base) break;
        cells += displayWidth(next.codepoint);
        end += next.len;
        expects_joined_base = false;
    }
    return .{ .len = end - index, .cells = cells, .valid = true, .sanitize = false };
}

fn isControlCodepoint(codepoint: u21) bool {
    return codepoint < 0x20 or codepoint == 0x7f or (codepoint >= 0x80 and codepoint <= 0x9f);
}

fn isClusterExtender(codepoint: u21) bool {
    return (codepoint >= 0x0300 and codepoint <= 0x036f) or
        (codepoint >= 0x1ab0 and codepoint <= 0x1aff) or
        (codepoint >= 0x1dc0 and codepoint <= 0x1dff) or
        (codepoint >= 0x20d0 and codepoint <= 0x20ff) or
        (codepoint >= 0xfe00 and codepoint <= 0xfe0f) or
        (codepoint >= 0xfe20 and codepoint <= 0xfe2f) or
        (codepoint >= 0xe0100 and codepoint <= 0xe01ef) or
        codepoint == 0x200d or
        codepoint == 0x20e3 or
        isEmojiModifier(codepoint);
}

fn isEmojiModifier(codepoint: u21) bool {
    return codepoint >= 0x1f3fb and codepoint <= 0x1f3ff;
}

fn isEmojiPresentationBase(codepoint: u21) bool {
    // This deliberately covers the full commonly implemented emoji blocks,
    // including U+1F000..U+1F2FF which are easy to omit when only modern
    // pictographs are considered.  Over-counting text-style glyphs is safer
    // than allowing an emoji-presentation terminal to autowrap a repaint.
    return (codepoint >= 0x1f000 and codepoint <= 0x1faff) or
        (codepoint >= 0x2600 and codepoint <= 0x27ff);
}

fn displayWidth(codepoint: u21) usize {
    if ((codepoint >= 0x0300 and codepoint <= 0x036f) or (codepoint >= 0x200b and codepoint <= 0x200f) or
        (codepoint >= 0x202a and codepoint <= 0x202e) or (codepoint >= 0x2060 and codepoint <= 0x206f) or
        (codepoint >= 0xfe00 and codepoint <= 0xfe0f) or (codepoint >= 0xe0100 and codepoint <= 0xe01ef)) return 0;
    if ((codepoint >= 0x1100 and codepoint <= 0x115f) or (codepoint >= 0x2e80 and codepoint <= 0xa4cf) or
        (codepoint >= 0xac00 and codepoint <= 0xd7a3) or (codepoint >= 0xf900 and codepoint <= 0xfaff) or
        (codepoint >= 0xfe10 and codepoint <= 0xfe6f) or (codepoint >= 0xff01 and codepoint <= 0xff60) or
        (codepoint >= 0xffe0 and codepoint <= 0xffe6) or (codepoint >= 0x2300 and codepoint <= 0x27ff) or
        (codepoint >= 0x1f300 and codepoint <= 0x1faff) or
        (codepoint >= 0x20000 and codepoint <= 0x3fffd) or
        isEmojiPresentationBase(codepoint)) return 2;
    return 1;
}

// ────────────────────────────────────────────────────────────────────────────
//  Signal handling for cooperative cancellation
// ────────────────────────────────────────────────────────────────────────────

/// Global pointer to the active cancellation flag.  Only one
/// `runWithProgress` call is active at a time (it runs on the main
/// thread), so a single global is safe.
const CancelHandler = if (builtin.os.tag == .windows or builtin.os.tag == .wasi or builtin.os.tag == .freestanding) struct {
    const Previous = void;

    fn install(_: *std.atomic.Value(bool)) ?Previous {
        return null;
    }

    fn uninstall(_: ?Previous) void {}
} else struct {
    var global_cancel: ?*std.atomic.Value(bool) = null;

    fn sigintHandler(sig: std.c.SIG) callconv(.c) void {
        _ = sig;
        if (global_cancel) |cancel| cancel.store(true, .release);
    }

    const Previous = std.c.Sigaction;

    fn install(cancel: *std.atomic.Value(bool)) ?Previous {
        global_cancel = cancel;

        const act = std.c.Sigaction{
            .handler = .{ .handler = &sigintHandler },
            .mask = std.mem.zeroes(std.c.sigset_t),
            .flags = 0,
        };

        var old_int: std.c.Sigaction = undefined;
        if (std.c.sigaction(.INT, &act, &old_int) != 0) {
            global_cancel = null;
            return null;
        }
        var old_term: std.c.Sigaction = undefined;
        if (std.c.sigaction(.TERM, &act, &old_term) != 0) {
            _ = std.c.sigaction(.INT, &old_int, null);
            global_cancel = null;
            return null;
        }

        return old_int;
    }

    fn uninstall(old: ?Previous) void {
        if (old) |*action| {
            _ = std.c.sigaction(.INT, action, null);
            _ = std.c.sigaction(.TERM, action, null);
        }
        global_cancel = null;
    }
};

// ────────────────────────────────────────────────────────────────────────────
//  Events
// ────────────────────────────────────────────────────────────────────────────

/// Events sent from worker threads to the UI thread.
///
/// String slices in events must outlive their consumption by the UI thread.
/// In practice they are either compile-time string literals or allocated from
/// the process-level arena (which lives for the entire process), so they are
/// always valid when the UI thread reads them.
pub const TaskStateUpdate = struct {
    task_id: []const u8,
    revision: u64,
    state: []const u8,
    message: []const u8,
};

pub const ProgressEvent = union(enum) {
    phase_started: []const u8,
    phase_done: []const u8,

    status: struct {
        id: []const u8,
        msg: []const u8,
    },

    task_state: TaskStateUpdate,

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

    pub fn sendTaskState(
        self: *WorkerContext,
        task_id: []const u8,
        revision: u64,
        state: []const u8,
        message: []const u8,
    ) void {
        self.queue.send(.{ .task_state = .{
            .task_id = self.allocator.dupe(u8, task_id) catch return,
            .revision = revision,
            .state = self.allocator.dupe(u8, state) catch return,
            .message = self.allocator.dupe(u8, message) catch return,
        } });
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
    const TaskRow = struct {
        task_id: []const u8,
        revision: u64,
        state: []const u8,
        message: []const u8,
        slot: ?usize,
        active: bool,
        terminal: bool,
    };

    const max_visible_tasks = 5;

    writer: *std.Io.Writer,
    is_tty: bool,
    io: std.Io,
    columns: usize,
    env: ?*std.process.Environ.Map,

    // render state
    spinner_frame: usize = 0,
    current_phase: []const u8 = "",
    current_package: ?[]const u8 = null,
    dl_label: []const u8 = "",
    dl_done: u64 = 0,
    dl_total: ?u64 = null,
    dl_seen: bool = false,
    last_render_ns: i128 = 0,

    // cancellation state
    stopping: bool = false,
    stopped_count: usize = 0,
    stop_total: usize = 0,

    // track previous line length for space-padding
    last_line_len: usize = 0,
    rendered_lines: usize = 0,

    task_rows: std.ArrayList(TaskRow),
    task_slots: [max_visible_tasks]?usize = .{ null, null, null, null, null },
    completed_tasks: usize = 0,
    frame_writer: std.Io.Writer.Allocating,
    content_writer: std.Io.Writer.Allocating,

    // accumulated warnings to print at the end
    warnings: std.ArrayList([]const u8),

    const render_interval_ns: i128 = 16 * std.time.ns_per_ms; // ~60 fps

    pub fn init(
        writer: *std.Io.Writer,
        is_tty: bool,
        io: std.Io,
        columns: usize,
        env: ?*std.process.Environ.Map,
    ) ProgressUi {
        return .{
            .writer = writer,
            .is_tty = is_tty,
            .io = io,
            .columns = columns,
            .env = env,
            .warnings = .empty,
            .task_rows = .empty,
            .frame_writer = std.Io.Writer.Allocating.init(std.heap.page_allocator),
            .content_writer = std.Io.Writer.Allocating.init(std.heap.page_allocator),
        };
    }

    pub fn deinit(self: *ProgressUi) void {
        self.warnings.deinit(std.heap.page_allocator);
        self.task_rows.deinit(std.heap.page_allocator);
        self.frame_writer.deinit();
        self.content_writer.deinit();
    }

    /// Write directly to stderr, bypassing the buffered Threaded I/O writer.
    /// This ensures spinner frames are written atomically so carriage-return
    /// actually returns the cursor to column 0 instead of being split across writes.
    fn rawWrite(self: *ProgressUi, data: []const u8) void {
        if (builtin.os.tag == .wasi or builtin.os.tag == .freestanding) {
            self.writer.writeAll(data) catch {};
            self.writer.flush() catch {};
            return;
        }

        std.Io.File.stderr().writeStreamingAll(self.io, data) catch {};
    }

    pub fn apply(self: *ProgressUi, event: ProgressEvent) void {
        switch (event) {
            .phase_started => |msg| {
                self.current_phase = msg;
                self.current_package = null;
                self.dl_label = "";
                self.dl_done = 0;
                self.dl_total = null;
                self.dl_seen = false;
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
                self.dl_seen = false;

                if (self.is_tty) {
                    self.clearRenderedRows();
                    self.renderTaskLine(true, "⠿ {s}", .{msg});
                    self.rawWrite("\n");
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
            .task_state => |update| self.applyTaskState(update),
            .bytes => |b| {
                self.dl_label = b.label;
                self.dl_done = b.done;
                self.dl_total = b.total;
                self.dl_seen = true;

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

    fn applyTaskState(self: *ProgressUi, update: TaskStateUpdate) void {
        for (self.task_rows.items) |*row| {
            if (!std.mem.eql(u8, row.task_id, update.task_id)) continue;
            if (!row.active or update.revision <= row.revision) return;
            row.revision = update.revision;
            row.state = update.state;
            row.message = update.message;
            if (isTerminalTaskState(update.state)) {
                row.active = false;
                row.terminal = true;
                self.completed_tasks += 1;
            }
            return;
        }

        const row_index = self.task_rows.items.len;
        const slot = self.firstAvailableTaskSlot();
        const terminal = isTerminalTaskState(update.state);
        self.task_rows.append(std.heap.page_allocator, .{
            .task_id = update.task_id,
            .revision = update.revision,
            .state = update.state,
            .message = update.message,
            .slot = slot,
            .active = !terminal,
            .terminal = terminal,
        }) catch return;
        if (slot) |value| self.task_slots[value] = row_index;
        if (terminal) self.completed_tasks += 1;
    }

    fn firstAvailableTaskSlot(self: *const ProgressUi) ?usize {
        for (self.task_slots, 0..) |entry, index| {
            if (entry == null) return index;
        }
        return null;
    }

    fn promoteOverflowTasks(self: *ProgressUi) void {
        for (&self.task_slots, 0..) |*slot, slot_index| {
            if (slot.* != null) continue;
            for (self.task_rows.items, 0..) |*row, row_index| {
                if (!row.active or row.slot != null) continue;
                row.slot = slot_index;
                slot.* = row_index;
                break;
            }
        }
    }

    fn activeOverflowTaskCount(self: *const ProgressUi) usize {
        var count: usize = 0;
        for (self.task_rows.items) |row| {
            if (row.active and row.slot == null) count += 1;
        }
        return count;
    }

    fn visibleTaskCount(self: *const ProgressUi) usize {
        var count: usize = 0;
        for (self.task_slots) |slot| {
            if (slot != null) count += 1;
        }
        return count;
    }

    /// Keep terminal transitions on screen for one paint. This makes short,
    /// concurrent operations observable instead of letting a queue drain erase
    /// every row before the next frame is rendered.
    fn releaseRenderedTerminalTaskRows(self: *ProgressUi) void {
        for (&self.task_slots) |*slot| {
            const row_index = slot.* orelse continue;
            const row = &self.task_rows.items[row_index];
            if (!row.terminal) continue;
            row.terminal = false;
            row.slot = null;
            slot.* = null;
        }
        self.promoteOverflowTasks();
    }

    fn isTerminalTaskState(state: []const u8) bool {
        return std.mem.eql(u8, state, "completed") or
            std.mem.eql(u8, state, "failed") or
            std.mem.eql(u8, state, "cancelled") or
            std.mem.eql(u8, state, "reused");
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
        // Multiline task rows rely on terminal cursor controls. Never emit
        // them into a redirected stream: each repaint would become a new log
        // line instead of replacing the previous frame.
        if (!self.is_tty) return;
        self.refreshColumns();

        if (self.visibleTaskCount() > 0) {
            self.renderTaskRows();
            return;
        }
        const frame = spinner_frames[self.spinner_frame % spinner_frames.len];
        self.spinner_frame +%= 1;

        // If we have byte progress, show a filling bar.
        if (!self.stopping and self.dl_total != null) {
            const total = self.dl_total.?;
            const fraction = if (total > 0)
                @as(f32, @floatFromInt(self.dl_done)) / @as(f32, @floatFromInt(total))
            else
                0;
            self.renderBar(frame, fraction);
            return;
        }

        const has_no_visible_work =
            !self.stopping and
            self.current_phase.len == 0 and
            self.current_package == null and
            !self.dl_seen;

        if (has_no_visible_work) return;

        // Otherwise, show a spinner line. Use the reusable allocating writer:
        // package names and URLs may be larger than a stack buffer, and are
        // end-clamped only after their complete display width is known.
        self.content_writer.clearRetainingCapacity();
        const writer = &self.content_writer.writer;
        writer.print("{s} ", .{frame}) catch return;

        if (self.stopping) {
            // Cancellation phase: show "Stopping… x/y"
            if (self.stop_total > 0) {
                writer.print("Stopping… {d}/{d}", .{ self.stopped_count, self.stop_total }) catch {};
            } else {
                writer.writeAll("Stopping…") catch {};
            }
        } else {
            if (self.current_phase.len > 0) {
                writer.print("{s}", .{self.current_phase}) catch {};
            }
            if (self.current_package) |pkg| {
                writer.print(" → {s}", .{pkg}) catch {};
            }
            if (self.dl_seen and self.dl_total == null) {
                if (self.dl_label.len > 0) {
                    writer.print(" {s}", .{self.dl_label}) catch {};
                }
                writer.writeAll(" (") catch {};
                byteQuantity(self.dl_done).write(writer) catch {};
                writer.writeByte(')') catch {};
            }
        }
        self.renderBoundedLine(writer.buffered());
    }

    fn clearRenderedRows(self: *ProgressUi) void {
        if (!self.is_tty or self.rendered_lines == 0) return;
        var buffer: [64]u8 = undefined;
        if (self.rendered_lines > 1) {
            const up = std.fmt.bufPrint(&buffer, "\x1b[{d}A", .{self.rendered_lines - 1}) catch return;
            self.rawWrite(up);
        }
        self.rawWrite("\r");
        for (0..self.rendered_lines) |index| {
            self.rawWrite("\x1b[2K");
            if (index + 1 < self.rendered_lines) self.rawWrite("\x1b[1B\r");
        }
        if (self.rendered_lines > 1) {
            const back = std.fmt.bufPrint(&buffer, "\x1b[{d}A", .{self.rendered_lines - 1}) catch return;
            self.rawWrite(back);
        }
        self.rawWrite("\r");
        self.rendered_lines = 0;
    }

    fn renderBoundedLine(self: *ProgressUi, text: []const u8) void {
        self.refreshColumns();
        self.renderBoundedLineAtColumns(text);
    }

    fn renderBoundedLineAtColumns(self: *ProgressUi, text: []const u8) void {
        self.frame_writer.clearRetainingCapacity();
        self.frame_writer.writer.writeAll("\x1b[2K\r") catch return;
        appendBounded(&self.frame_writer.writer, text, self.columns) catch return;
        self.rawWrite(self.frame_writer.writer.buffered());
    }

    fn renderTaskLine(self: *ProgressUi, is_last: bool, comptime fmt: []const u8, args: anytype) void {
        self.content_writer.clearRetainingCapacity();
        self.content_writer.writer.print(fmt, args) catch return;
        const text = self.content_writer.writer.buffered();
        self.renderBoundedLine(text);
        if (!is_last) self.rawWrite("\n");
    }

    fn renderTaskRows(self: *ProgressUi) void {
        self.clearRenderedRows();

        const phase_lines: usize = if (self.current_phase.len > 0) 1 else 0;
        const task_lines = self.visibleTaskCount();

        const overflow = self.activeOverflowTaskCount();
        const overflow_lines: usize = if (overflow > 0) 1 else 0;
        const completed_lines: usize = if (self.completed_tasks > 0) 1 else 0;
        const lines = phase_lines + task_lines + overflow_lines + completed_lines;
        if (lines == 0) return;

        var written: usize = 0;
        if (self.current_phase.len > 0) {
            written += 1;
            self.renderTaskLine(written == lines, "{s}", .{self.current_phase});
        }

        for (self.task_slots) |maybe_row_index| {
            const row_index = maybe_row_index orelse continue;
            const row = self.task_rows.items[row_index];
            written += 1;
            if (row.terminal) {
                const mark: []const u8 = if (std.mem.eql(u8, row.state, "completed")) "✓" else "✗";
                self.renderTaskLine(written == lines, "{s} {s}: {s}", .{ mark, row.state, row.message });
            } else {
                const frame = spinner_frames[self.spinner_frame % spinner_frames.len];
                self.renderTaskLine(written == lines, "{s} {s}: {s}", .{ frame, row.state, row.message });
            }
        }
        if (overflow > 0) {
            written += 1;
            self.renderTaskLine(written == lines, "… {d} more tasks queued", .{overflow});
        }
        if (self.completed_tasks > 0) {
            written += 1;
            self.renderTaskLine(written == lines, "✓ {d} task{s} completed", .{ self.completed_tasks, if (self.completed_tasks == 1) "" else "s" });
        }
        self.rendered_lines = lines;
        self.spinner_frame +%= 1;
        self.releaseRenderedTerminalTaskRows();
    }

    fn renderBar(self: *ProgressUi, frame: []const u8, fraction: f32) void {
        self.refreshColumns();
        const width = self.barWidth();
        self.content_writer.clearRetainingCapacity();
        const writer = &self.content_writer.writer;
        writer.print("{s}", .{frame}) catch return;

        if (width > 0) writer.writeAll(" [") catch return;

        const total_states = width * 8;
        const current_state = progressStates(fraction, total_states);

        for (0..width) |i| {
            const char_state = if (current_state >= (i + 1) * 8)
                8
            else if (current_state <= i * 8)
                0
            else
                current_state - i * 8;
            writer.print("{s}", .{fill_levels[char_state]}) catch {};
        }
        if (width > 0) writer.writeByte(']') catch {};
        writer.writeByte(' ') catch {};
        if (self.dl_label.len > 0) {
            writer.print("{s} ", .{self.dl_label}) catch {};
        } else if (self.current_package) |pkg| {
            writer.print("{s} ", .{pkg}) catch {};
        }
        byteQuantity(self.dl_done).write(writer) catch return;
        writer.writeByte('/') catch return;
        byteQuantity(self.dl_total.?).write(writer) catch return;
        self.renderBoundedLineAtColumns(writer.buffered());
    }

    fn barWidth(self: *const ProgressUi) usize {
        return barWidthForColumns(self.columns, 10);
    }

    fn refreshColumns(self: *ProgressUi) void {
        if (self.env) |env| self.columns = terminalColumns(self.io, env, true);
    }

    /// Called after the UI loop exits (on `.done` or `.failed`).
    /// Clears the spinner line and prints any accumulated warnings.
    pub fn renderFinal(self: *ProgressUi) void {
        if (self.is_tty) {
            self.clearRenderedRows();
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
        self.dl_seen = false;
    }

    /// A worker has stopped; increment the counter.
    pub fn onWorkerStopped(self: *ProgressUi) void {
        self.stopped_count += 1;
    }

    /// Print the final "Stopped x processes" line.
    pub fn renderStopped(self: *ProgressUi) void {
        const n = self.stopped_count;
        if (self.is_tty) {
            self.content_writer.clearRetainingCapacity();
            self.content_writer.writer.print("⠿ Stopped {d} process(es).", .{n}) catch {};
            self.renderBoundedLine(self.content_writer.writer.buffered());
            self.rawWrite("\n");
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
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    work_fn: *const fn (*WorkerContext) anyerror!void,
    cmd_data: ?*anyopaque,
) !void {
    const is_tty = std.Io.File.stderr().isTty(io) catch false;

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
    const old_sa = CancelHandler.install(&cancel);
    defer CancelHandler.uninstall(old_sa);

    // Spawn worker thread with a larger stack size (8MB) to avoid stack overflows
    // when parsing large structures (like MoonstoneToml) on platforms with small defaults.
    const spawn_config = std.Thread.SpawnConfig{ .stack_size = 8 * 1024 * 1024 };
    const thread = try std.Thread.spawn(spawn_config, workerMain, .{ work_fn, &wctx });
    defer thread.join();

    // Run UI loop on the main thread.
    var ui = ProgressUi.init(progress_writer, is_tty, io, terminalColumns(io, env, true), env);
    defer ui.deinit();

    const poll_sleep = std.Io.Duration.fromMilliseconds(16);
    var cancellation_shown = false;
    while (true) {
        // Drain all pending events.
        while (queue.tryRecv()) |event| {
            ui.apply(event);
            // Task lifecycle transitions are low-volume, semantic events.
            // Paint each transition before draining the next one so a fast
            // worker cannot collapse `preparing → materializing → completed`
            // into one invisible final row.
            if (is_tty and event == .task_state) {
                ui.last_render_ns = ui.nowNs();
                ui.render();
            }
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
    silent,

    pub fn phase(self: ProgressBackend, comptime fmt: []const u8, args: anytype) void {
        switch (self) {
            .direct => |w| {
                w.print(fmt ++ "\n", args) catch {};
                w.flush() catch {};
            },
            .queue => |wctx| {
                const tmp = formatQueuedText(wctx, fmt, args) orelse return;
                // Strip trailing newlines — the UI handles line breaks itself.
                const trimmed = std.mem.trimEnd(u8, tmp, "\n");
                wctx.sendPhase(trimmed);
            },
            .silent => {},
        }
    }

    pub fn phaseDone(self: ProgressBackend, comptime fmt: []const u8, args: anytype) void {
        switch (self) {
            .direct => |w| {
                w.print("⠿ " ++ fmt ++ "\n", args) catch {};
                w.flush() catch {};
            },
            .queue => |wctx| {
                const tmp = formatQueuedText(wctx, fmt, args) orelse return;
                wctx.sendPhaseDone(tmp);
            },
            .silent => {},
        }
    }

    pub fn packageStarted(self: ProgressBackend, name: []const u8) void {
        switch (self) {
            .direct => |w| {
                w.print("  → {s}\n", .{name}) catch {};
                w.flush() catch {};
            },
            .queue => |wctx| wctx.sendPackageStarted(name),
            .silent => {},
        }
    }

    pub fn packageDone(self: ProgressBackend, name: []const u8) void {
        switch (self) {
            .direct => {},
            .queue => |wctx| wctx.sendPackageDone(name),
            .silent => {},
        }
    }

    pub fn bytes(self: ProgressBackend, label: []const u8, done: u64, total: ?u64) void {
        switch (self) {
            .direct => {},
            .queue => |wctx| wctx.sendBytesOwned(label, done, total),
            .silent => {},
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
                const tmp = formatQueuedText(wctx, fmt, args) orelse return;
                const trimmed = std.mem.trimEnd(u8, tmp, "\n");
                wctx.sendStatus(id, trimmed);
            },
            .silent => {},
        }
    }

    pub fn warning(self: ProgressBackend, comptime fmt: []const u8, args: anytype) void {
        switch (self) {
            .direct => |w| {
                w.print("⚠ " ++ fmt ++ "\n", args) catch {};
                w.flush() catch {};
            },
            .queue => |wctx| {
                const tmp = formatQueuedText(wctx, fmt, args) orelse return;
                wctx.sendWarning(tmp);
            },
            .silent => {},
        }
    }
};

/// Progress strings cross the worker/UI boundary, so stack-backed formatting
/// would either truncate valid input or dangle before the UI can consume it.
/// Worker allocators are process-lifetime arenas for these commands, so the
/// formatted slice remains valid until the queue consumer has rendered it.
fn formatQueuedText(wctx: *WorkerContext, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    return std.fmt.allocPrint(wctx.allocator, fmt, args) catch null;
}

// ────────────────────────────────────────────────────────────────────────────
//  Callback adapters — translate core resolver/solver events to queue events
// ────────────────────────────────────────────────────────────────────────────

/// Adapter for `ResolveCallback` that forwards events through the queue.
pub fn onResolveEventProgress(ctx: ?*anyopaque, event: @import("moonstone").resolution.options.ResolveEvent) void {
    const wctx: *WorkerContext = @ptrCast(@alignCast(ctx orelse return));
    switch (event) {
        .retry => |r| {
            const tmp = formatQueuedText(
                wctx,
                "Retrying {s} ({d}/{d})",
                .{ r.url, r.attempt, r.max_retries },
            ) orelse return;

            // Retry attempts are volatile just like direct callback spinners.
            // Keep them out of non-TTY logs while still rendering them in the
            // interactive queue UI.
            wctx.sendStatus("resolver", tmp);
        },

        .status => |s| {
            const tmp = formatQueuedText(
                wctx,
                "{s}: {s}",
                .{ s.pkg_name, s.msg },
            ) orelse return;

            wctx.sendStatus("resolver", tmp);
        },

        .download_progress => |dp| {
            wctx.sendBytesOwned(
                dp.pkg_name orelse dp.url,
                @as(u64, @intCast(dp.downloaded_bytes)),
                if (dp.total_bytes) |t| @as(u64, @intCast(t)) else null,
            );
        },

        // Metadata start is volatile.  A non-TTY queue must match the direct
        // callback path: no start line, then one durable completion line.
        .metadata_sync_started => |label| wctx.sendStatus("metadata", label),
        .metadata_sync_done => |label| wctx.sendPhaseDone(label),
        .build_failed => |bf| {
            const msg = formatQueuedText(
                wctx,
                "Build failed for {s}. Command: {s}\nTail of stderr:\n{s}",
                .{ bf.pkg_name, bf.command, bf.stderr_tail },
            ) orelse return;
            wctx.sendWarning(msg);
            if (bf.log_path) |lp| {
                const log_msg = formatQueuedText(
                    wctx,
                    "Full build log for {s} saved to: {s}",
                    .{ bf.pkg_name, lp },
                ) orelse return;
                wctx.sendWarning(log_msg);
            }
        },
    }
}

/// Adapter for `SolverCallback` that forwards events through the queue.
pub fn onSolverEventProgress(ctx: ?*anyopaque, event: @import("moonstone").resolution.solver.report.SolverEvent, data: std.json.Value) void {
    const wctx: *WorkerContext = @ptrCast(@alignCast(ctx orelse return));
    if (data == .object) {
        if (data.object.get("package")) |pkg| {
            if (pkg == .string) {
                const tmp = switch (event) {
                    .resolving => formatQueuedText(wctx, "Solving: choosing version for {s}…", .{pkg.string}),
                    .propagating => formatQueuedText(wctx, "Solving: applying constraints for {s}…", .{pkg.string}),
                    .conflict => formatQueuedText(wctx, "Solving: conflict on {s}…", .{pkg.string}),
                    .backtracking => formatQueuedText(wctx, "Solving: backtracking from {s}…", .{pkg.string}),
                };
                const message = tmp orelse return;
                wctx.sendStatus("solver", message);
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

test "task rows keep terminal slots until the next render" {
    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 80, null);
    defer ui.deinit();

    ui.applyTaskState(.{ .task_id = "a", .revision = 1, .state = "running", .message = "a" });
    ui.applyTaskState(.{ .task_id = "b", .revision = 1, .state = "running", .message = "b" });
    ui.applyTaskState(.{ .task_id = "c", .revision = 1, .state = "running", .message = "c" });
    try std.testing.expectEqual(@as(?usize, 0), ui.task_rows.items[0].slot);
    try std.testing.expectEqual(@as(?usize, 1), ui.task_rows.items[1].slot);
    try std.testing.expectEqual(@as(?usize, 2), ui.task_rows.items[2].slot);

    ui.applyTaskState(.{ .task_id = "b", .revision = 2, .state = "completed", .message = "done" });
    try std.testing.expect(!ui.task_rows.items[1].active);
    try std.testing.expect(ui.task_rows.items[1].terminal);
    try std.testing.expectEqual(@as(?usize, 1), ui.task_rows.items[1].slot);
    try std.testing.expectEqual(@as(?usize, 2), ui.task_rows.items[2].slot);

    ui.applyTaskState(.{ .task_id = "d", .revision = 1, .state = "running", .message = "d" });
    try std.testing.expectEqual(@as(?usize, 3), ui.task_rows.items[3].slot);

    ui.releaseRenderedTerminalTaskRows();
    try std.testing.expect(ui.task_rows.items[1].slot == null);
    try std.testing.expectEqual(@as(?usize, 2), ui.task_rows.items[2].slot);
}

test "bounded frames sanitize controls, invalid UTF-8, and double-width characters" {
    var bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try appendBounded(&writer, "one\x1b\tc2\u{0085}\n🙂three\xe2", 12);
    try std.testing.expectEqualStrings("one  c2 ...", writer.buffered());

    var narrow: [16]u8 = undefined;
    var narrow_writer = std.Io.Writer.fixed(&narrow);
    try appendBounded(&narrow_writer, "ééé", 3);
    try std.testing.expectEqualStrings("éé", narrow_writer.buffered());
}

test "bounded frames sanitize controls after a ZWJ without exceeding the bound" {
    var bytes: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try appendBounded(&writer, "a\u{200d}\x1b[2J", 6);
    try std.testing.expectEqualStrings("a\u{200d} [2J", writer.buffered());
    var scan: usize = 0;
    while (scan < writer.buffered().len) {
        const codepoint = decodeCodepoint(writer.buffered(), scan);
        try std.testing.expect(codepoint.valid);
        try std.testing.expect(!isControlCodepoint(codepoint.codepoint));
        scan += codepoint.len;
    }
    // Six columns reserve one cell for autowrap, so the five-cell result is
    // admitted exactly rather than clamped or overrun.
    try std.testing.expectEqual(@as(usize, 5), displayWidth('a') + displayWidth(0x200d) + displayWidth(' ') + displayWidth('[') + displayWidth('2') + displayWidth('J'));
}

test "bounded frames conservatively preserve emoji-presentation graphemes" {
    var heart_bytes: [32]u8 = undefined;
    var heart_writer = std.Io.Writer.fixed(&heart_bytes);
    // Each heart is a narrow text base plus VS16, but common terminals render
    // it as two cells.  A two-cell budget must never admit both hearts.
    try appendBounded(&heart_writer, "❤️❤️", 3);
    try std.testing.expectEqualStrings("❤️", heart_writer.buffered());

    var zwj_bytes: [32]u8 = undefined;
    var zwj_writer = std.Io.Writer.fixed(&zwj_bytes);
    // Reserve ellipsis first, then refuse a partial woman-technologist ZWJ
    // grapheme rather than writing a dangling joiner before the clamp.
    try appendBounded(&zwj_writer, "👩‍💻xy", 6);
    try std.testing.expectEqualStrings("...", zwj_writer.buffered());
}

test "queue metadata start is volatile and completion is printed once on non-TTY" {
    var queue = try ProgressQueue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit(std.testing.allocator);
    var cancel = std.atomic.Value(bool).init(false);
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var wctx = WorkerContext{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .env = &env_map,
        .queue = &queue,
        .cancel = &cancel,
    };

    onResolveEventProgress(&wctx, .{ .metadata_sync_started = "Syncing registry" });
    onResolveEventProgress(&wctx, .{ .metadata_sync_done = "Registry synced" });

    var bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 80, null);
    defer ui.deinit();
    while (queue.tryRecv()) |event| ui.apply(event);
    try std.testing.expectEqualStrings("Registry synced\n", writer.buffered());
}

test "queued status preserves long formatted strings" {
    var queue = try ProgressQueue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit(std.testing.allocator);
    var cancel = std.atomic.Value(bool).init(false);
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var wctx = WorkerContext{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .env = &env_map,
        .queue = &queue,
        .cancel = &cancel,
    };
    const long_name = try arena.allocator().alloc(u8, 1024);
    @memset(long_name, 'x');

    const backend = ProgressBackend{ .queue = &wctx };
    backend.status("resolver", "Solving: {s}", .{long_name});

    const event = queue.tryRecv() orelse {
        try std.testing.expect(false);
        return;
    };
    switch (event) {
        .status => |status| {
            try std.testing.expectEqualStrings("resolver", status.id);
            try std.testing.expectEqual(@as(usize, "Solving: ".len + long_name.len), status.msg.len);
        },
        else => try std.testing.expect(false),
    }
}

test "bar states clamp over-complete and zero-total fractions" {
    try std.testing.expectEqual(@as(usize, 80), progressStates(1.1, 80));
    try std.testing.expectEqual(@as(usize, 0), progressStates(0, 80));
    try std.testing.expectEqual(@as(usize, 0), progressStates(0, 0));
}

test "bounded frames honor narrow medium and wide row budgets" {
    const cases = [_]struct { columns: usize, expected: []const u8 }{
        .{ .columns = 20, .expected = "⠋ resolving moon..." },
        .{ .columns = 60, .expected = "⠋ resolving moonstone/ballad" },
        .{ .columns = 120, .expected = "⠋ resolving moonstone/ballad" },
    };
    for (cases) |case| {
        var bytes: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try appendBounded(&writer, "⠋ resolving moonstone/ballad", case.columns);
        try std.testing.expectEqualStrings(case.expected, writer.buffered());
    }
}

test "bounded frames leave no printable content in zero-width budgets" {
    const cases = [_]usize{ 0, 1 };
    for (cases) |columns| {
        var bytes: [16]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try appendBounded(&writer, "frame", columns);
        try std.testing.expectEqualStrings("", writer.buffered());
    }
}

test "bounded frames end-clamp long task names and URLs at exact cell boundaries" {
    const text = "⠋ running moonstone/ballad from https://registry.example.invalid/a/very/long/artifact.tar.gz";
    const cases = [_]struct { columns: usize, expected: []const u8 }{
        .{ .columns = 2, .expected = "⠋" },
        .{ .columns = 3, .expected = "⠋ " },
        .{ .columns = 4, .expected = "..." },
        .{ .columns = 7, .expected = "⠋ r..." },
        .{ .columns = 8, .expected = "⠋ ru..." },
    };
    for (cases) |case| {
        var bytes: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try appendBounded(&writer, text, case.columns);
        try std.testing.expectEqualStrings(case.expected, writer.buffered());
    }

    var exact: [16]u8 = undefined;
    var exact_writer = std.Io.Writer.fixed(&exact);
    try appendBounded(&exact_writer, "abcdef", 7);
    try std.testing.expectEqualStrings("abcdef", exact_writer.buffered());
}

test "byte quantities use binary units with stable one-decimal alignment" {
    const Case = struct { value: u64, expected: []const u8 };
    const cases = [_]Case{
        .{ .value = 0, .expected = "0.0  B" },
        .{ .value = 1, .expected = "1.0  B" },
        .{ .value = 1023, .expected = "1023.0  B" },
        .{ .value = 1024, .expected = "1.0 KB" },
        .{ .value = 1536, .expected = "1.5 KB" },
        .{ .value = 1024 * 1024 - 51, .expected = "1.0 MB" },
        .{ .value = std.math.maxInt(u64), .expected = "16.0 EB" },
    };
    for (cases) |case| {
        var bytes: [32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try byteQuantity(case.value).write(&writer);
        try std.testing.expectEqualStrings(case.expected, writer.buffered());
    }
}

test "bar layout yields label space at narrow breakpoints" {
    try std.testing.expectEqual(@as(usize, 0), barWidthForColumns(0, 10));
    try std.testing.expectEqual(@as(usize, 0), barWidthForColumns(59, 10));
    try std.testing.expectEqual(@as(usize, 10), barWidthForColumns(60, 10));
    try std.testing.expectEqual(@as(usize, 10), barWidthForColumns(99, 10));
    try std.testing.expectEqual(@as(usize, 20), barWidthForColumns(100, 10));
    try std.testing.expectEqual(@as(usize, 14), barWidthForColumns(120, 7));
}

test "task rows ignore stale revisions" {
    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 80, null);
    defer ui.deinit();

    ui.applyTaskState(.{ .task_id = "a", .revision = 2, .state = "prepared", .message = "new" });
    ui.applyTaskState(.{ .task_id = "a", .revision = 1, .state = "running", .message = "stale" });

    try std.testing.expectEqual(@as(u64, 2), ui.task_rows.items[0].revision);
    try std.testing.expectEqualStrings("prepared", ui.task_rows.items[0].state);
    try std.testing.expectEqualStrings("new", ui.task_rows.items[0].message);
}

test "terminal task rows promote queued work after one paint" {
    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 80, null);
    defer ui.deinit();

    const ids = [_][]const u8{ "a", "b", "c", "d", "e", "f" };
    for (ids) |task_id| {
        ui.applyTaskState(.{ .task_id = task_id, .revision = 1, .state = "running", .message = task_id });
    }
    try std.testing.expectEqual(@as(usize, 1), ui.activeOverflowTaskCount());
    try std.testing.expect(ui.task_rows.items[5].slot == null);

    ui.applyTaskState(.{ .task_id = "c", .revision = 2, .state = "completed", .message = "done" });
    try std.testing.expectEqual(@as(?usize, 2), ui.task_rows.items[2].slot);
    try std.testing.expect(ui.task_rows.items[5].slot == null);

    ui.releaseRenderedTerminalTaskRows();
    try std.testing.expectEqual(@as(?usize, 2), ui.task_rows.items[5].slot);
    try std.testing.expectEqual(@as(?usize, 0), ui.task_rows.items[0].slot);
    try std.testing.expectEqual(@as(?usize, 1), ui.task_rows.items[1].slot);
    try std.testing.expectEqual(@as(?usize, 3), ui.task_rows.items[3].slot);
    try std.testing.expectEqual(@as(?usize, 4), ui.task_rows.items[4].slot);
}
