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

pub fn terminalRows(io: std.Io, env: ?*std.process.Environ.Map, use_stderr: bool) usize {
    const fallback = if (env) |e| rowsFromEnv(e) orelse 24 else 24;
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi or builtin.os.tag == .freestanding) return fallback;

    var winsize: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const file = if (use_stderr) std.Io.File.stderr() else std.Io.File.stdout();
    const result = io.operate(.{ .device_io_control = .{
        .file = file,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &winsize,
    } }) catch return fallback;
    if (result.device_io_control >= 0 and winsize.row > 0) return winsize.row;
    return fallback;
}

fn rowsFromEnv(env: *std.process.Environ.Map) ?usize {
    const raw = env.get("LINES") orelse return null;
    const rows = std.fmt.parseUnsigned(usize, raw, 10) catch return null;
    return if (rows > 1) rows else null;
}

pub fn clampVisibleRows(total_items: usize, max_cap: usize, terminal_rows_count: usize) usize {
    const height_budget = if (terminal_rows_count > 5) terminal_rows_count - 5 else 1;
    const budget = @min(max_cap, height_budget);
    return @min(total_items, budget);
}

/// Reserves the last terminal cell so a repaint never triggers terminal autowrap.
pub fn appendBounded(writer: *std.Io.Writer, text: []const u8, columns: usize) !void {
    return appendBoundedWithGlyphMode(writer, text, columns, .ascii);
}

fn appendBoundedWithGlyphMode(writer: *std.Io.Writer, text: []const u8, columns: usize, glyph_mode: GlyphMode) !void {
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
    const ellipsis_cells: usize = switch (glyph_mode) {
        .unicode => 1,
        .ascii => 3,
    };
    const content_limit = if (truncated and limit >= ellipsis_cells) limit - ellipsis_cells else limit;
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
    if (truncated and limit >= ellipsis_cells) try writer.writeAll(switch (glyph_mode) {
        .unicode => "…",
        .ascii => "...",
    });
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

/// Runtime-selected visual grammar for fancy progress. `MOONSTONE_PROGRESS_GLYPHS`
/// accepts `unicode` (the default) or `ascii`; this narrow environment setting
/// is intentionally separate from plain/JSON output contracts.
pub const GlyphMode = enum { unicode, ascii };

pub fn glyphModeFromSetting(value: ?[]const u8) GlyphMode {
    const setting = value orelse return .unicode;
    return if (std.ascii.eqlIgnoreCase(setting, "ascii")) .ascii else .unicode;
}

const package_units = [_][]const u8{ "  B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" };

pub const PackageBytePair = struct {
    done_whole: u64,
    done_tenths: u4,
    total_whole: u64,
    total_tenths: u4,
    unit: []const u8,
};

fn roundedTenths(value: u64, scale: u64) u128 {
    return (@as(u128, value) * 10 + scale / 2) / scale;
}

/// Pick exactly one binary unit from the total, promoting when rounding would
/// produce 1000.0. Both fields then use that same scale, so progress detail
/// never jitters between MiB and GiB while a transfer advances.
pub fn packageBytePair(done: u64, total: u64) PackageBytePair {
    var unit_index: usize = 0;
    var scale: u64 = 1;
    var total_tenths = roundedTenths(total, scale);
    while (unit_index + 1 < package_units.len and total_tenths >= 10_000) {
        scale *= 1024;
        unit_index += 1;
        total_tenths = roundedTenths(total, scale);
    }
    const done_tenths = roundedTenths(done, scale);
    return .{
        .done_whole = @intCast(done_tenths / 10),
        .done_tenths = @intCast(done_tenths % 10),
        .total_whole = @intCast(total_tenths / 10),
        .total_tenths = @intCast(total_tenths % 10),
        .unit = package_units[unit_index],
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

/// Display cells under the same Unicode/control policy as bounded package
/// frames. Tests use this rather than byte offsets for stable-column proofs.
fn displayCells(text: []const u8) usize {
    var cells: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const cluster = boundedCluster(text, index);
        cells += cluster.cells;
        index += cluster.len;
    }
    return cells;
}

fn stripRendererAnsi(writer: *std.Io.Writer, text: []const u8) !void {
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b and index + 1 < text.len and text[index + 1] == '[') {
            index += 2;
            while (index < text.len) : (index += 1) {
                if (text[index] >= '@' and text[index] <= '~') {
                    index += 1;
                    break;
                }
            }
            continue;
        }
        try writer.writeByte(text[index]);
        index += 1;
    }
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
        _ = std.c.write(std.posix.STDERR_FILENO, "\x1b[?25h", 6);
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
/// `ProgressQueue.send` clones string payloads while holding its producer lock.
/// Producers may therefore use stack-local formatting buffers; the queue keeps
/// event payloads alive until the UI and queue have both shut down.
pub const TaskStateUpdate = struct {
    task_id: []const u8,
    revision: u64,
    state: []const u8,
    message: []const u8,
};

/// A concrete package realization known before its workers are started.  This
/// deliberately is not a resolver/metadata task: package rows model the
/// materialization closure, so their denominator cannot change as callbacks
/// arrive from concurrent workers.
pub const PackageInventory = struct {
    task_id: []const u8,
    name: []const u8,
    detail: []const u8,
    /// Artifact/source identity, when known. It affects only the stable visual
    /// identity; task_id remains the lifecycle key.
    discriminator: []const u8 = "",
    total_bytes: ?u64 = null,
    reused: bool = false,
};

pub const ByteProgress = struct {
    /// Canonical task identity when the producer has it. Package determinate
    /// progress accepts byte events only when this is present and `total` is
    /// known; name-only and indeterminate events remain legacy/global UI data.
    task_id: ?[]const u8 = null,
    label: []const u8,
    done: u64,
    total: ?u64,
};

pub const ProgressEvent = union(enum) {
    phase_started: []const u8,
    phase_done: []const u8,

    status: struct {
        id: []const u8,
        msg: []const u8,
    },

    task_state: TaskStateUpdate,

    package_inventory: PackageInventory,

    package_started: []const u8,
    package_done: []const u8,

    bytes: ByteProgress,

    warning: []const u8,
    done,
    failed: []const u8,
};

// ────────────────────────────────────────────────────────────────────────────
//  Queue — bounded MPSC ring buffer
// ────────────────────────────────────────────────────────────────────────────

/// Volatile progress uses a bounded overwrite ring. Inventory, lifecycle, and
/// terminal events use the separate reliable lane: losing one of those would
/// change a package denominator or leave a row nonterminal. The reliable lane
/// is intentionally allowed to apply backpressure through allocation failure
/// (which panics rather than silently reporting a false aggregate); it is not
/// an enlarged version of the volatile queue.
pub const ProgressQueue = struct {
    items: []ProgressEvent,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    reliable: std.ArrayList(ProgressEvent) = .empty,
    reliable_head: usize = 0,
    /// Reliable payloads remain alive through UI shutdown because package and
    /// task rows retain their slices. Volatile payloads instead live in their
    /// ring slot (or one in-flight hand-off) and are released on overwrite or
    /// after the next receive, keeping byte-progress memory bounded.
    reliable_payloads: std.ArrayList([]u8) = .empty,
    in_flight_volatile: ?ProgressEvent = null,
    volatile_payload_bytes: usize = 0,
    mutex: std.Io.Mutex = .init,
    io: std.Io,

    const default_capacity = 256;

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !ProgressQueue {
        const items = try allocator.alloc(ProgressEvent, default_capacity);
        return .{ .items = items, .io = io };
    }

    pub fn deinit(self: *ProgressQueue, allocator: std.mem.Allocator) void {
        if (self.in_flight_volatile) |event| self.freeVolatileEvent(event);
        var index = self.tail;
        for (0..self.count) |_| {
            self.freeVolatileEvent(self.items[index]);
            index = (index + 1) % self.items.len;
        }
        allocator.free(self.items);
        self.reliable.deinit(std.heap.page_allocator);
        for (self.reliable_payloads.items) |payload| std.heap.page_allocator.free(payload);
        self.reliable_payloads.deinit(std.heap.page_allocator);
    }

    fn isReliable(event: ProgressEvent) bool {
        return switch (event) {
            .package_inventory, .task_state, .warning, .done, .failed => true,
            else => false,
        };
    }

    fn copySlice(self: *ProgressQueue, value: []const u8, reliable: bool) ![]const u8 {
        const copy = try std.heap.page_allocator.dupe(u8, value);
        errdefer std.heap.page_allocator.free(copy);
        if (reliable) {
            try self.reliable_payloads.append(std.heap.page_allocator, copy);
        } else {
            self.volatile_payload_bytes += copy.len;
        }
        return copy;
    }

    fn freeVolatileSlice(self: *ProgressQueue, value: []const u8) void {
        self.volatile_payload_bytes -= value.len;
        std.heap.page_allocator.free(@constCast(value));
    }

    /// Frees only a non-reliable event. Reliable events are intentionally held
    /// until queue teardown because the reducer retains their strings.
    fn freeVolatileEvent(self: *ProgressQueue, event: ProgressEvent) void {
        switch (event) {
            .phase_started => |message| self.freeVolatileSlice(message),
            .phase_done => |message| self.freeVolatileSlice(message),
            .status => |status| {
                self.freeVolatileSlice(status.id);
                self.freeVolatileSlice(status.msg);
            },
            .package_started => |name| self.freeVolatileSlice(name),
            .package_done => |name| self.freeVolatileSlice(name),
            .bytes => |progress| {
                if (progress.task_id) |task_id| self.freeVolatileSlice(task_id);
                self.freeVolatileSlice(progress.label);
            },
            .package_inventory, .task_state, .warning, .done, .failed => unreachable,
        }
    }

    /// Must be called with `mutex` held. Page allocation is deliberately kept
    /// inside that critical section: the command allocator is often an arena
    /// shared by workers and is not itself an MPSC allocation boundary.
    fn cloneEvent(self: *ProgressQueue, event: ProgressEvent, reliable: bool) !ProgressEvent {
        return switch (event) {
            .phase_started => |message| .{ .phase_started = try self.copySlice(message, reliable) },
            .phase_done => |message| .{ .phase_done = try self.copySlice(message, reliable) },
            .status => |status| .{ .status = .{
                .id = try self.copySlice(status.id, reliable),
                .msg = try self.copySlice(status.msg, reliable),
            } },
            .task_state => |update| .{ .task_state = .{
                .task_id = try self.copySlice(update.task_id, reliable),
                .revision = update.revision,
                .state = try self.copySlice(update.state, reliable),
                .message = try self.copySlice(update.message, reliable),
            } },
            .package_inventory => |inventory| .{ .package_inventory = .{
                .task_id = try self.copySlice(inventory.task_id, reliable),
                .name = try self.copySlice(inventory.name, reliable),
                .detail = try self.copySlice(inventory.detail, reliable),
                .discriminator = try self.copySlice(inventory.discriminator, reliable),
                .total_bytes = inventory.total_bytes,
                .reused = inventory.reused,
            } },
            .package_started => |name| .{ .package_started = try self.copySlice(name, reliable) },
            .package_done => |name| .{ .package_done = try self.copySlice(name, reliable) },
            .bytes => |progress| .{ .bytes = .{
                .task_id = if (progress.task_id) |task_id| try self.copySlice(task_id, reliable) else null,
                .label = try self.copySlice(progress.label, reliable),
                .done = progress.done,
                .total = progress.total,
            } },
            .warning => |message| .{ .warning = try self.copySlice(message, reliable) },
            .done => .done,
            .failed => |message| .{ .failed = try self.copySlice(message, reliable) },
        };
    }

    pub fn send(self: *ProgressQueue, event: ProgressEvent) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const reliable = isReliable(event);
        const owned = self.cloneEvent(event, reliable) catch {
            if (reliable) @panic("progress reliable queue out of memory");
            return;
        };
        if (reliable) {
            // A truthful terminal UI is preferable to silently continuing with
            // a smaller denominator under an unrecoverable OOM condition.
            self.reliable.append(std.heap.page_allocator, owned) catch @panic("progress reliable queue out of memory");
            return;
        }
        if (self.count == self.items.len) self.freeVolatileEvent(self.items[self.head]);
        self.items[self.head] = owned;
        self.head = (self.head + 1) % self.items.len;
        if (self.count < self.items.len) {
            self.count += 1;
        } else {
            self.tail = (self.tail + 1) % self.items.len;
        }
    }

    /// A returned volatile event remains valid until the next `tryRecv` call;
    /// the UI consumes/copies its transient fields before polling again.
    pub fn tryRecv(self: *ProgressQueue) ?ProgressEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.in_flight_volatile) |event| {
            self.freeVolatileEvent(event);
            self.in_flight_volatile = null;
        }
        if (self.reliable_head < self.reliable.items.len) {
            const event = self.reliable.items[self.reliable_head];
            self.reliable_head += 1;
            if (self.reliable_head == self.reliable.items.len) {
                self.reliable.clearRetainingCapacity();
                self.reliable_head = 0;
            }
            return event;
        }
        if (self.count == 0) return null;
        const event = self.items[self.tail];
        self.items[self.tail] = .done;
        self.tail = (self.tail + 1) % self.items.len;
        self.count -= 1;
        self.in_flight_volatile = event;
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

    pub fn sendBytesOwnedForTask(
        self: *WorkerContext,
        task_id: []const u8,
        label: []const u8,
        done: u64,
        total: ?u64,
    ) void {
        self.send(.{ .bytes = .{
            .task_id = task_id,
            .label = label,
            .done = done,
            .total = total,
        } });
    }

    pub fn sendPackageInventory(self: *WorkerContext, inventory: PackageInventory) void {
        self.send(.{ .package_inventory = inventory });
    }

    pub fn sendBytesOwned(
        self: *WorkerContext,
        label: []const u8,
        done: u64,
        total: ?u64,
    ) void {
        self.send(.{
            .bytes = .{
                .label = label,
                .done = done,
                .total = total,
            },
        });
    }

    pub fn sendStatus(self: *WorkerContext, id: []const u8, msg: []const u8) void {
        self.send(.{
            .status = .{
                .id = id,
                .msg = msg,
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
            .task_id = task_id,
            .revision = revision,
            .state = state,
            .message = message,
        } });
    }

    pub fn sendWarning(self: *WorkerContext, msg: []const u8) void {
        self.send(.{ .warning = msg });
    }
};

// ────────────────────────────────────────────────────────────────────────────
//  UI — Docker-style braille spinner + filling progress bar
// ────────────────────────────────────────────────────────────────────────────

const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const fill_levels = [_][]const u8{ "⠀", "⡀", "⣀", "⣄", "⣤", "⣦", "⣶", "⣷", "⣿" };

/// Stable package lifecycle states.  Textual task protocol states are reduced
/// into this closed set at the UI boundary; rendering never infers package
/// completion from a phase string.
pub const PackageState = enum { queued, active, ready, failed, cancelled };

/// Closed vocabulary rendered by package rows. Protocol aliases are mapped at
/// the reducer boundary; arbitrary producer strings never become UI grammar.
const PackageStatus = enum {
    queued,
    downloading,
    verifying,
    extracting,
    preparing,
    compiling,
    linking,
    materializing,
    ready,
    failed,
    cancelled,
};

fn packageStatusForProtocol(state: []const u8) PackageStatus {
    if (std.mem.eql(u8, state, "completed") or std.mem.eql(u8, state, "reused")) return .ready;
    if (std.mem.eql(u8, state, "failed")) return .failed;
    if (std.mem.eql(u8, state, "cancelled") or std.mem.eql(u8, state, "skipped")) return .cancelled;
    if (std.mem.eql(u8, state, "queued") or std.mem.eql(u8, state, "waiting")) return .queued;
    if (std.mem.eql(u8, state, "downloading") or std.mem.eql(u8, state, "running") or std.mem.eql(u8, state, "fetching")) return .downloading;
    if (std.mem.eql(u8, state, "verifying")) return .verifying;
    if (std.mem.eql(u8, state, "extracting")) return .extracting;
    if (std.mem.eql(u8, state, "preparing") or std.mem.eql(u8, state, "prepared")) return .preparing;
    if (std.mem.eql(u8, state, "compiling") or std.mem.eql(u8, state, "building")) return .compiling;
    if (std.mem.eql(u8, state, "linking")) return .linking;
    if (std.mem.eql(u8, state, "materializing")) return .materializing;
    // Unknown protocol strings are not presentation vocabulary. Treat them as
    // pending rather than smuggling arbitrary producer wording into the row.
    return .queued;
}

fn packageStateForStatus(status: PackageStatus) PackageState {
    return switch (status) {
        .ready => .ready,
        .failed => .failed,
        .cancelled => .cancelled,
        .queued => .queued,
        .downloading, .verifying, .extracting, .preparing, .compiling, .linking, .materializing => .active,
    };
}

fn packageStatusWord(status: PackageStatus) []const u8 {
    return switch (status) {
        .queued => "queued",
        .downloading => "downloading",
        .verifying => "verifying",
        .extracting => "extracting",
        .preparing => "preparing",
        .compiling => "compiling",
        .linking => "linking",
        .materializing => "materializing",
        .ready => "ready",
        .failed => "failed",
        .cancelled => "cancelled",
    };
}

pub const PackageCounts = struct {
    ready: usize = 0,
    active: usize = 0,
    queued: usize = 0,
    failed: usize = 0,
    cancelled: usize = 0,
    pub fn total(self: PackageCounts) usize {
        return self.ready + self.active + self.queued + self.failed + self.cancelled;
    }
};

pub fn writePackageSummary(writer: *std.Io.Writer, counts: PackageCounts, glyph_mode: GlyphMode) !void {
    const total = counts.total();
    const sep = switch (glyph_mode) {
        .unicode => " · ",
        .ascii => " - ",
    };
    try writer.print("Installing {d} packages{s}{d} ready, {d} active", .{
        total,
        sep,
        counts.ready,
        counts.active,
    });
    if (counts.failed > 0) {
        try writer.print(", {d} failed", .{counts.failed});
    }
}

pub const PackageBreakpoint = enum { compact, normal, wide };

/// Fixed geometry for a package row.  `progress_cells` is a *column*, not an
/// individual package's bar width. This is cached/recomputed only when the
/// terminal crosses a named breakpoint.
pub const PackageLayout = struct {
    breakpoint: PackageBreakpoint,
    progress_cells: usize,
    name_cells: usize,
    detail_start: usize,
    row_limit: usize,
};

pub fn packageLayout(columns: usize) PackageLayout {
    const limit = columns -| 1;
    const breakpoint: PackageBreakpoint = if (columns < 60) .compact else if (columns < 100) .normal else .wide;
    const progress_cells: usize = switch (breakpoint) {
        .compact => 3,
        .normal => 5,
        .wide => 7,
    };
    // status + separating space + progress + separating space. Compact has no
    // detail and deliberately degrades the fixed name column on truly narrow
    // terminals rather than allowing a line to wrap.
    const desired_name: usize = switch (breakpoint) {
        .compact => 12,
        .normal => 24,
        .wide => 32,
    };
    const available_name = limit -| (2 + progress_cells + 1);
    const name_cells = @min(desired_name, available_name);
    return .{
        .breakpoint = breakpoint,
        .progress_cells = progress_cells,
        .name_cells = name_cells,
        .detail_start = 2 + progress_cells + 1 + name_cells + 2,
        .row_limit = limit,
    };
}

fn packageSeed(task_id: []const u8, discriminator: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update("braille-progress-v1");
    hasher.update(task_id);
    hasher.update("\x00");
    hasher.update(discriminator);
    return hasher.final();
}

fn nextPermutationRandom(state: *u64) u64 {
    state.* +%= 0x9e3779b97f4a7c15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// Builds the cached dot order once per package. A later progress value merely
/// selects a prefix, which makes the lit-dot set monotonic without hashing or
/// allocating during frames.
pub fn braillePermutation(seed: u64) [56]u8 {
    var result: [56]u8 = undefined;
    for (&result, 0..) |*item, index| item.* = @intCast(index);
    var random = seed;
    var i: usize = result.len;
    while (i > 1) {
        i -= 1;
        const j: usize = @intCast(nextPermutationRandom(&random) % (i + 1));
        std.mem.swap(u8, &result[i], &result[j]);
    }
    return result;
}

pub fn determinateDotCount(done: u64, total: u64, width: usize) usize {
    if (total == 0) return 0;
    return @intCast((@as(u128, @min(done, total)) * width * 8) / total);
}

/// Pure frame data for a determinate package. The returned masks contain only
/// the assigned logical cells; callers reserve their wider layout column.
pub fn brailleDotMasks(permutation: [56]u8, width: usize, done: u64, total: u64) [7]u8 {
    var masks: [7]u8 = .{ 0, 0, 0, 0, 0, 0, 0 };
    const dots = determinateDotCount(done, total, width);
    if (dots == 0) return masks;
    var lit: usize = 0;
    for (permutation) |dot| {
        const position: usize = dot;
        if (position >= width * 8) continue;
        masks[position / 8] |= @as(u8, 1) << @intCast(position % 8);
        lit += 1;
        if (lit == dots) break;
    }
    return masks;
}

/// Bytes are determinate only while the lifecycle explicitly denotes a
/// transfer. Source preparation, extraction, verification and builds can all
/// emit unrelated byte-like counters; rendering those as a package download
/// would be false progress.
fn phaseAllowsByteProgress(phase: []const u8) bool {
    return packageStatusForProtocol(phase) == .downloading;
}

fn writeBrailleMask(writer: *std.Io.Writer, mask: u8) !void {
    var bytes: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(@as(u21, 0x2800) + mask, &bytes);
    try writer.writeAll(bytes[0..len]);
}

pub const ProgressUi = struct {
    const PackageRow = struct {
        task_id: []const u8,
        name: []const u8,
        detail: []const u8,
        discriminator: []const u8 = "",
        state: PackageState,
        status: PackageStatus,
        phase: []const u8 = "queued",
        revision: u64 = 0,
        done: u64 = 0,
        total: ?u64,
        seed: u64,
        permutation: [56]u8,
    };

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
    rows: usize = 24,
    max_visible_rows: usize = 5,
    env: ?*std.process.Environ.Map,
    glyph_mode: GlyphMode,
    package_layout: PackageLayout,

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
    // Inventory order is sorted by canonical task identity once, before
    // workers start. Arrival order never controls a package's row position.
    package_rows: std.ArrayList(PackageRow),
    task_slots: [max_visible_tasks]?usize = .{ null, null, null, null, null },
    completed_tasks: usize = 0,
    completed_phases: std.ArrayList([]const u8),
    frame_writer: std.Io.Writer.Allocating,
    content_writer: std.Io.Writer.Allocating,
    bounded_writer: std.Io.Writer.Allocating,
    phase_storage: std.Io.Writer.Allocating,
    package_storage: std.Io.Writer.Allocating,
    download_label_storage: std.Io.Writer.Allocating,

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
        const rows = if (env) |map| terminalRows(io, map, true) else 24;
        const max_vis = std.math.clamp(rows -| 5, @as(usize, 1), @as(usize, 25));
        var ui = ProgressUi{
            .writer = writer,
            .is_tty = is_tty,
            .io = io,
            .columns = columns,
            .rows = rows,
            .max_visible_rows = max_vis,
            .env = env,
            .glyph_mode = glyphModeFromSetting(if (env) |map| map.get("MOONSTONE_PROGRESS_GLYPHS") else null),
            .package_layout = packageLayout(columns),
            .warnings = .empty,
            .completed_phases = .empty,
            .task_rows = .empty,
            .package_rows = .empty,
            .frame_writer = std.Io.Writer.Allocating.init(std.heap.page_allocator),
            .content_writer = std.Io.Writer.Allocating.init(std.heap.page_allocator),
            .bounded_writer = std.Io.Writer.Allocating.init(std.heap.page_allocator),
            .phase_storage = std.Io.Writer.Allocating.init(std.heap.page_allocator),
            .package_storage = std.Io.Writer.Allocating.init(std.heap.page_allocator),
            .download_label_storage = std.Io.Writer.Allocating.init(std.heap.page_allocator),
        };
        if (is_tty) ui.rawWrite("\x1b[?25l");
        return ui;
    }

    pub fn deinit(self: *ProgressUi) void {
        if (self.is_tty) self.rawWrite("\x1b[?25h");
        for (self.completed_phases.items) |p| std.heap.page_allocator.free(@constCast(p));
        self.completed_phases.deinit(std.heap.page_allocator);
        self.warnings.deinit(std.heap.page_allocator);
        self.task_rows.deinit(std.heap.page_allocator);
        self.package_rows.deinit(std.heap.page_allocator);
        self.frame_writer.deinit();
        self.content_writer.deinit();
        self.bounded_writer.deinit();
        self.phase_storage.deinit();
        self.package_storage.deinit();
        self.download_label_storage.deinit();
    }

    /// Write directly to stderr, bypassing the buffered Threaded I/O writer.
    /// This ensures spinner frames are written atomically so carriage-return
    /// actually returns the cursor to column 0 instead of being split across writes.
    fn rawWrite(self: *ProgressUi, data: []const u8) void {
        // Unit tests use the supplied fixed writer to assert terminal-control
        // ordering; production still uses the direct stderr path below.
        if (builtin.is_test) {
            self.writer.writeAll(data) catch {};
            return;
        }
        if (builtin.os.tag == .wasi or builtin.os.tag == .freestanding) {
            self.writer.writeAll(data) catch {};
            self.writer.flush() catch {};
            return;
        }

        std.Io.File.stderr().writeStreamingAll(self.io, data) catch {};
    }

    fn setPhase(self: *ProgressUi, phase: []const u8) void {
        self.phase_storage.clearRetainingCapacity();
        self.phase_storage.writer.writeAll(phase) catch {
            self.current_phase = "";
            return;
        };
        self.current_phase = self.phase_storage.writer.buffered();
    }

    fn setCurrentPackage(self: *ProgressUi, package: []const u8) void {
        self.package_storage.clearRetainingCapacity();
        self.package_storage.writer.writeAll(package) catch {
            self.current_package = null;
            return;
        };
        self.current_package = self.package_storage.writer.buffered();
    }

    fn setDownloadLabel(self: *ProgressUi, label: []const u8) void {
        self.download_label_storage.clearRetainingCapacity();
        self.download_label_storage.writer.writeAll(label) catch {
            self.dl_label = "";
            return;
        };
        self.dl_label = self.download_label_storage.writer.buffered();
    }

    pub fn apply(self: *ProgressUi, event: ProgressEvent) void {
        switch (event) {
            .phase_started => |msg| {
                self.setPhase(msg);
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

                // Deduplicate phase_done if already synced
                for (self.completed_phases.items) |completed| {
                    if (std.mem.eql(u8, completed, msg)) return;
                }
                const owned_msg = std.heap.page_allocator.dupe(u8, msg) catch return;
                self.completed_phases.append(std.heap.page_allocator, owned_msg) catch {
                    std.heap.page_allocator.free(owned_msg);
                    return;
                };

                if (self.is_tty) {
                    self.clearRenderedRows();
                    self.content_writer.clearRetainingCapacity();
                    self.content_writer.writer.print("⠿ {s}", .{msg}) catch return;
                    self.renderBoundedLine(self.content_writer.writer.buffered());
                    self.rawWrite("\n");
                    self.rendered_lines = 0;
                } else {
                    self.writer.print("{s}\n", .{msg}) catch {};
                }
                self.writer.flush() catch {};
            },
            .package_started => |name| {
                self.setCurrentPackage(name);
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
            .package_inventory => |inventory| self.applyPackageInventory(inventory),
            .bytes => |b| {
                if (self.applyPackageBytes(b)) return;
                self.setDownloadLabel(b.label);
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

                self.setPhase(s.msg);

                // Important:
                // Do NOT print volatile status in non-TTY/direct mode.
                // Otherwise CI/non-interactive logs get spammed.
            },
            .done, .failed => {},
        }
    }

    fn applyTaskState(self: *ProgressUi, update: TaskStateUpdate) void {
        for (self.package_rows.items) |*row| {
            if (!std.mem.eql(u8, row.task_id, update.task_id)) continue;
            if (update.revision <= row.revision) return;
            row.revision = update.revision;
            // Keep the structured operation name separate from the human
            // message. Normal-width rows expose this phase rather than
            // pretending non-byte work has a percentage.
            row.status = packageStatusForProtocol(update.state);
            row.phase = packageStatusWord(row.status);
            row.state = packageStateForStatus(row.status);
            if (row.state == .ready and row.total != null) row.done = row.total.?;
            return;
        }
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

    fn applyPackageInventory(self: *ProgressUi, inventory: PackageInventory) void {
        for (self.package_rows.items) |*row| {
            if (std.mem.eql(u8, row.task_id, inventory.task_id)) {
                if (inventory.reused and row.state == .queued) {
                    row.state = .ready;
                    row.status = .ready;
                    row.phase = "reused";
                }
                return;
            }
        }
        const seed = packageSeed(inventory.task_id, inventory.discriminator);
        // Inventory arrives before scheduling, but use ordered insertion rather
        // than repeatedly sorting the complete closure: O(n) movement avoids
        // O(n² log n) comparison work while preserving canonical row order.
        var insert_at: usize = 0;
        while (insert_at < self.package_rows.items.len and std.mem.order(u8, self.package_rows.items[insert_at].task_id, inventory.task_id) == .lt) : (insert_at += 1) {}
        self.package_rows.insert(std.heap.page_allocator, insert_at, .{
            .task_id = inventory.task_id,
            .name = inventory.name,
            .detail = inventory.detail,
            .discriminator = inventory.discriminator,
            .state = if (inventory.reused) .ready else .queued,
            .status = if (inventory.reused) .ready else .queued,
            .phase = if (inventory.reused) "reused" else "queued",
            .total = inventory.total_bytes,
            .seed = seed,
            .permutation = braillePermutation(seed),
        }) catch return;
    }

    fn applyPackageBytes(self: *ProgressUi, update: ByteProgress) bool {
        // A package row is a claim about a concrete transfer, not merely a
        // similarly named legacy callback. Its determinate Braille cells may
        // advance only from a task-attributed byte event with a denominator.
        // Return false so untagged/indeterminate callbacks still retain the
        // established global/direct progress behavior.
        const task_id = update.task_id orelse return false;
        const total = update.total orelse return false;
        for (self.package_rows.items) |*row| {
            if (!std.mem.eql(u8, row.task_id, task_id)) continue;
            // Reliable lifecycle events may overtake older volatile byte
            // events. A terminal state owns its final visual truth; never let
            // a delayed 50/100 callback turn a completed full bar back into
            // partial detail.
            switch (row.state) {
                .ready, .failed, .cancelled => return true,
                .queued, .active => {},
            }
            // The overwrite ring can also expose callbacks out of order. Keep
            // the greatest observed byte count, and establish a total once
            // rather than oscillating between stale advertised totals. A known
            // inventory total is equally authoritative and is never overwritten
            // here.
            row.done = @max(row.done, update.done);
            if (row.total == null) row.total = total;
            if (row.state == .queued) row.state = .active;
            return true;
        }
        return false;
    }

    pub fn packageCounts(self: *const ProgressUi) PackageCounts {
        var counts: PackageCounts = .{};
        for (self.package_rows.items) |row| switch (row.state) {
            .ready => counts.ready += 1,
            .active => counts.active += 1,
            .queued => counts.queued += 1,
            .failed => counts.failed += 1,
            .cancelled => counts.cancelled += 1,
        };
        return counts;
    }

    /// Failure and cancellation stop schedulers before they can necessarily
    /// emit a terminal event for every inventory member. Make that visible
    /// instead of clearing an ambiguous queued/active row at final repaint.
    pub fn reconcileIncompletePackages(self: *ProgressUi) void {
        for (self.package_rows.items) |*row| switch (row.state) {
            .queued, .active => {
                row.state = .cancelled;
                row.status = .cancelled;
                row.phase = "cancelled";
            },
            else => {},
        };
    }

    fn renderReconciledPackages(self: *ProgressUi) void {
        if (!self.is_tty or self.package_rows.items.len == 0) return;
        self.render();
        // Pin the final complete frame before warnings/errors are printed.
        self.rawWrite("\n");
        self.rendered_lines = 0;
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

    const CompletionDisposition = enum { transient_clear, durable_package_frame };

    /// Cached local work can complete before (or immediately after) a regular
    /// repaint. Pin its final multi-package aggregate on its own newline so
    /// `renderFinal` clears only the fresh empty line, never that evidence.
    /// A one-package cache hit remains transient to avoid a needless flash.
    fn completionDisposition(self: *const ProgressUi) CompletionDisposition {
        if (!self.is_tty or self.package_rows.items.len <= 1) return .transient_clear;
        for (self.package_rows.items) |row| {
            if (row.state != .ready or !std.mem.eql(u8, row.phase, "reused")) return .transient_clear;
        }
        return .durable_package_frame;
    }

    fn pinDurablePackageCompletion(self: *ProgressUi) void {
        self.render();
        // `renderPackageRows` intentionally has no trailing newline because it
        // normally owns a repaint region. Once complete, terminate that region
        // before final cleanup so later shell output begins on a clean line.
        self.rawWrite("\n");
        self.rendered_lines = 0;
    }

    pub fn render(self: *ProgressUi) void {
        // Multiline task rows rely on terminal cursor controls. Never emit
        // them into a redirected stream: each repaint would become a new log
        // line instead of replacing the previous frame.
        if (!self.is_tty) return;
        self.refreshColumns();

        if (self.package_rows.items.len > 0) {
            self.renderPackageRows();
            return;
        }

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
        appendBoundedWithGlyphMode(&self.frame_writer.writer, text, self.columns, self.glyph_mode) catch return;
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

    fn writeFixedCells(writer: *std.Io.Writer, text: []const u8, cells: usize, glyph_mode: GlyphMode) !void {
        var used: usize = 0;
        var index: usize = 0;
        // Fixed columns intentionally use an ASCII end clamp. The helper also
        // sanitizes terminal controls exactly like the outer bounded renderer.
        var total: usize = 0;
        var scan: usize = 0;
        while (scan < text.len) {
            const cluster = boundedCluster(text, scan);
            total += cluster.cells;
            scan += cluster.len;
        }
        const clamped = total > cells;
        const ellipsis_cells: usize = switch (glyph_mode) {
            .unicode => 1,
            .ascii => 3,
        };
        const content_limit = if (clamped and cells >= ellipsis_cells) cells - ellipsis_cells else cells;
        while (index < text.len) {
            const cluster = boundedCluster(text, index);
            if (cluster.cells > content_limit -| used) break;
            if (cluster.sanitize) try writer.writeByte(' ') else if (cluster.valid) try writer.writeAll(text[index..][0..cluster.len]) else try writer.writeAll("\u{fffd}");
            used += cluster.cells;
            index += cluster.len;
        }
        if (clamped and cells >= ellipsis_cells) {
            try writer.writeAll(switch (glyph_mode) {
                .unicode => "…",
                .ascii => "...",
            });
            used += ellipsis_cells;
        }
        for (used..cells) |_| try writer.writeByte(' ');
    }

    fn writePackageProgress(self: *ProgressUi, writer: *std.Io.Writer, row: *const PackageRow) !void {
        const column = self.package_layout.progress_cells;
        var masks: [7]u8 = .{ 0, 0, 0, 0, 0, 0, 0 };
        if (row.state == .ready) {
            for (masks[0..column]) |*mask| mask.* = 0xff;
        } else if (row.state == .active and phaseAllowsByteProgress(row.phase) and row.total != null and row.total.? > 0) {
            masks = brailleDotMasks(row.permutation, column, row.done, row.total.?);
        } else if (row.state == .active and column > 0) {
            // Indeterminate active: packageStatus owns the 1st-column spinner.
            // writePackageProgress leaves masks as all 0s (blank braille cells or dots in ascii).
        } else if (row.state == .failed and column > 0) {
            masks[0] = 0x09;
        } else if (row.state == .cancelled and column > 0) {
            masks[0] = 0x81;
        }
        for (masks[0..column]) |mask| switch (self.glyph_mode) {
            .unicode => try writeBrailleMask(writer, mask),
            .ascii => try writer.writeByte(if (mask == 0) '.' else '#'),
        };
    }

    fn packageStatus(self: *const ProgressUi, row: *const PackageRow) []const u8 {
        if (self.package_layout.breakpoint == .compact) return switch (self.glyph_mode) {
            .unicode => switch (row.status) {
                // These all measure one cell under `displayWidth`; avoid the
                // attractive U+25xx/U+27xx symbols that this renderer treats
                // as ambiguous/wide on conservative terminals.
                .queued => "·",
                .downloading => " ",
                .verifying => "?",
                .extracting => "↧",
                .preparing => "o",
                .compiling => "c",
                .linking => "↔",
                .materializing => "*",
                .ready => "+",
                .failed => "x",
                .cancelled => "-",
            },
            .ascii => switch (row.status) {
                .queued => "o",
                .downloading => " ",
                .verifying => "?",
                .extracting => "v",
                .preparing => "o",
                .compiling => "c",
                .linking => "<",
                .materializing => "*",
                .ready => "+",
                .failed => "x",
                .cancelled => "-",
            },
        };
        return switch (self.glyph_mode) {
            .unicode => switch (row.state) {
                .ready => "+",
                .failed => "x",
                .cancelled => "-",
                .queued => "·",
                .active => spinner_frames[self.spinner_frame % spinner_frames.len],
            },
            .ascii => switch (row.state) {
                .ready => "+",
                .failed => "x",
                .cancelled => "-",
                .queued => "o",
                .active => "*",
            },
        };
    }

    fn writeNumericField(self: *const ProgressUi, writer: *std.Io.Writer, whole: u64, tenths: u4) !void {
        var number: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&number, "{d}.{d}", .{ whole, tenths });
        // Totals choose a unit that fits. A transferred count may exceed an
        // advertised total; preserve its honest digits rather than truncating.
        const padding = 5 -| text.len;
        const placeholder: []const u8 = switch (self.glyph_mode) {
            .unicode => "•",
            .ascii => ".",
        };
        for (0..padding) |_| try writer.writeAll(placeholder);
        try writer.writeAll(text);
    }

    fn writePackageDetail(self: *ProgressUi, writer: *std.Io.Writer, row: *const PackageRow) !void {
        switch (self.package_layout.breakpoint) {
            .compact => {},
            .normal => {
                try writer.print("{s}: {s}@{s}", .{ packageStatusWord(row.status), row.name, row.detail });
            },
            .wide => {
                if (row.status == .downloading and row.total != null) {
                    const total = row.total.?;
                    const pair = packageBytePair(row.done, total);
                    try self.writeNumericField(writer, pair.done_whole, pair.done_tenths);
                    try writer.writeAll(" / ");
                    try self.writeNumericField(writer, pair.total_whole, pair.total_tenths);
                    try writer.print(" {s}", .{pair.unit});
                } else {
                    try writer.writeAll(packageStatusWord(row.status));
                }
            },
        }
    }

    /// Pure-in-practice row construction used by the renderer and snapshots:
    /// it contains no ANSI, and all variable text is constrained after fixed
    /// columns have been emitted.
    fn buildPackageLine(self: *ProgressUi, row: *const PackageRow) []const u8 {
        self.content_writer.clearRetainingCapacity();
        const writer = &self.content_writer.writer;
        writer.print("{s} ", .{self.packageStatus(row)}) catch return "";
        self.writePackageProgress(writer, row) catch return "";
        writer.writeByte(' ') catch return "";
        writeFixedCells(writer, row.name, self.package_layout.name_cells, self.glyph_mode) catch return "";
        if (self.package_layout.breakpoint != .compact and self.package_layout.detail_start < self.package_layout.row_limit) {
            writer.writeAll("  ") catch return "";
            self.writePackageDetail(writer, row) catch return "";
        }
        return writer.buffered();
    }

    /// Applies renderer-owned dim styling only after pure text has been width
    /// clamped. Package-controlled bytes are never copied into escape
    /// sequences, and U+2022 is styled only in the numeric-detail column.
    fn renderStyledPackageLine(self: *ProgressUi, line: []const u8) void {
        self.bounded_writer.clearRetainingCapacity();
        appendBoundedWithGlyphMode(&self.bounded_writer.writer, line, self.columns, self.glyph_mode) catch return;
        const bounded = self.bounded_writer.writer.buffered();
        self.frame_writer.clearRetainingCapacity();
        const writer = &self.frame_writer.writer;
        writer.writeAll("\x1b[2K\r") catch return;
        var index: usize = 0;
        var cells: usize = 0;
        while (index < bounded.len) {
            const cluster = boundedCluster(bounded, index);
            const codepoint = decodeCodepoint(bounded, index);
            const dim_bullet = self.glyph_mode == .unicode and
                cells >= self.package_layout.detail_start and
                codepoint.valid and codepoint.codepoint == 0x2022;
            if (dim_bullet) writer.writeAll("\x1b[2m") catch return;
            if (cluster.sanitize) writer.writeByte(' ') catch return else writer.writeAll(bounded[index..][0..cluster.len]) catch return;
            if (dim_bullet) writer.writeAll("\x1b[22m") catch return;
            cells += cluster.cells;
            index += cluster.len;
        }
        self.rawWrite(writer.buffered());
    }

    fn renderPackageRows(self: *ProgressUi) void {
        self.clearRenderedRows();
        const max_vis = self.max_visible_rows;
        const total_pkgs = self.package_rows.items.len;
        const visible_limit = @min(total_pkgs, max_vis);

        var visible_indices: [32]usize = undefined;
        var vis_count: usize = 0;

        // Partition 1: active rows (stably sorted by task_id)
        for (self.package_rows.items, 0..) |row, idx| {
            if (row.state == .active) {
                if (vis_count < visible_limit) {
                    visible_indices[vis_count] = idx;
                    vis_count += 1;
                }
            }
        }

        // Partition 2: queued rows
        if (vis_count < visible_limit) {
            for (self.package_rows.items, 0..) |row, idx| {
                if (row.state == .queued) {
                    visible_indices[vis_count] = idx;
                    vis_count += 1;
                    if (vis_count == visible_limit) break;
                }
            }
        }

        // Partition 3: other rows (ready, failed, cancelled)
        if (vis_count < visible_limit) {
            for (self.package_rows.items, 0..) |row, idx| {
                if (row.state != .active and row.state != .queued) {
                    visible_indices[vis_count] = idx;
                    vis_count += 1;
                    if (vis_count == visible_limit) break;
                }
            }
        }

        const visible = vis_count;
        const overflow = total_pkgs - visible;
        const counts = self.packageCounts();
        // The aggregate is intentionally absent for one package; a single row
        // already says more than a redundant denominator.
        const summary_lines: usize = if (counts.total() > 1) 1 else 0;
        const overflow_lines: usize = if (overflow > 0) 1 else 0;
        const lines = visible + overflow_lines + summary_lines;
        var written: usize = 0;
        for (visible_indices[0..visible]) |row_idx| {
            const row = &self.package_rows.items[row_idx];
            written += 1;
            // buildPackageLine uses content_writer, so it must be sent directly
            // rather than passed through renderTaskLine (which clears that same
            // writer before formatting). This also keeps package rows ANSI-free
            // until the outer repaint boundary.
            self.renderStyledPackageLine(self.buildPackageLine(row));
            if (written != lines) self.rawWrite("\n");
        }
        if (overflow > 0) {
            written += 1;
            self.renderTaskLine(written == lines, "… {d} more packages", .{overflow});
        }
        if (summary_lines > 0) {
            written += 1;
            self.content_writer.clearRetainingCapacity();
            writePackageSummary(&self.content_writer.writer, counts, self.glyph_mode) catch return;
            self.renderBoundedLineAtColumns(self.content_writer.writer.buffered());
            if (written != lines) self.rawWrite("\n");
        }
        self.rendered_lines = lines;
        self.spinner_frame +%= 1;
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

    pub fn refreshGeometry(self: *ProgressUi) void {
        if (self.env) |env| {
            const next_cols = terminalColumns(self.io, env, true);
            const next_rows = terminalRows(self.io, env, true);
            if (packageLayout(next_cols).breakpoint != self.package_layout.breakpoint) {
                self.package_layout = packageLayout(next_cols);
            }
            self.columns = next_cols;
            self.rows = next_rows;
            self.max_visible_rows = std.math.clamp(next_rows -| 5, @as(usize, 1), @as(usize, 25));
        }
    }

    pub fn refreshColumns(self: *ProgressUi) void {
        self.refreshGeometry();
    }

    /// Called after the UI loop exits (on `.done` or `.failed`).
    /// Clears the spinner line and prints any accumulated warnings.
    pub fn renderFinal(self: *ProgressUi) void {
        if (self.is_tty) {
            self.clearRenderedRows();
            self.rawWrite("\x1b[2K\r");
            self.rawWrite("\x1b[?25h");
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
            self.rawWrite("\x1b[?25h");
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

    errdefer if (is_tty) {
        if (builtin.is_test) {
            progress_writer.writeAll("\x1b[?25h") catch {};
        } else {
            std.Io.File.stderr().writeStreamingAll(io, "\x1b[?25h") catch {};
        }
    };

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
                    if (is_tty) {
                        const counts = ui.packageCounts();
                        if (counts.total() > 0) {
                            if (ui.completionDisposition() == .durable_package_frame) {
                                ui.pinDurablePackageCompletion();
                            } else {
                                ui.clearRenderedRows();
                                ui.content_writer.clearRetainingCapacity();
                                ui.content_writer.writer.print("⠿ Synchronized {d} package{s}", .{
                                    counts.total(),
                                    if (counts.total() == 1) "" else "s",
                                }) catch {};
                                ui.renderBoundedLine(ui.content_writer.writer.buffered());
                                ui.rawWrite("\n");
                                ui.rendered_lines = 0;
                            }
                        }
                    }
                    ui.renderFinal();
                    return;
                },
                .failed => {
                    if (cancel.load(.acquire)) {
                        // Worker stopped due to cancellation.
                        ui.reconcileIncompletePackages();
                        ui.renderReconciledPackages();
                        ui.onWorkerStopped();
                        ui.renderStopped();
                        return error.Cancelled;
                    }
                    ui.reconcileIncompletePackages();
                    ui.renderReconciledPackages();
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

test "package byte pairs normalize both fields to total unit across rollovers" {
    const Case = struct { done: u64, total: u64, unit: []const u8, done_text: []const u8, total_text: []const u8 };
    const cases = [_]Case{
        .{ .done = 0, .total = 0, .unit = "  B", .done_text = "0.0", .total_text = "0.0" },
        .{ .done = 7, .total = 12, .unit = "  B", .done_text = "7.0", .total_text = "12.0" },
        .{ .done = 512, .total = 1023, .unit = "KiB", .done_text = "0.5", .total_text = "1.0" },
        .{ .done = 1024, .total = 1024, .unit = "KiB", .done_text = "1.0", .total_text = "1.0" },
        .{ .done = 1024 * 1024 - 51, .total = 1024 * 1024 - 51, .unit = "MiB", .done_text = "1.0", .total_text = "1.0" },
        .{ .done = std.math.maxInt(u64), .total = std.math.maxInt(u64), .unit = "EiB", .done_text = "16.0", .total_text = "16.0" },
    };
    for (cases) |case| {
        const pair = packageBytePair(case.done, case.total);
        var done: [32]u8 = undefined;
        var total: [32]u8 = undefined;
        const done_text = try std.fmt.bufPrint(&done, "{d}.{d}", .{ pair.done_whole, pair.done_tenths });
        const total_text = try std.fmt.bufPrint(&total, "{d}.{d}", .{ pair.total_whole, pair.total_tenths });
        try std.testing.expectEqualStrings(case.unit, pair.unit);
        try std.testing.expectEqualStrings(case.done_text, done_text);
        try std.testing.expectEqualStrings(case.total_text, total_text);
    }
}

test "glyph modes select explicit unicode and ascii numeric grammar" {
    try std.testing.expectEqual(GlyphMode.unicode, glyphModeFromSetting(null));
    try std.testing.expectEqual(GlyphMode.unicode, glyphModeFromSetting("unicode"));
    try std.testing.expectEqual(GlyphMode.ascii, glyphModeFromSetting("ASCII"));

    var bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 100, null);
    defer ui.deinit();
    try ui.writeNumericField(&writer, 7, 4);
    try std.testing.expectEqualStrings("••7.4", writer.buffered());
    try std.testing.expectEqual(@as(usize, 5), displayCells(writer.buffered()));

    var ascii_bytes: [64]u8 = undefined;
    var ascii_writer = std.Io.Writer.fixed(&ascii_bytes);
    ui.glyph_mode = .ascii;
    try ui.writeNumericField(&ascii_writer, 12, 1);
    try std.testing.expectEqualStrings(".12.1", ascii_writer.buffered());
    try std.testing.expectEqual(@as(usize, 5), displayCells(ascii_writer.buffered()));
}

test "package detail dims only unicode numeric bullets after pure width layout" {
    var output: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var ui = ProgressUi.init(&writer, true, std.testing.io, 100, null);
    defer ui.deinit();
    ui.apply(.{ .package_inventory = .{ .task_id = "p", .name = "p", .detail = "1", .total_bytes = 12 } });
    ui.apply(.{ .task_state = .{ .task_id = "p", .revision = 1, .state = "downloading", .message = "download" } });
    ui.apply(.{ .bytes = .{ .task_id = "p", .label = "p", .done = 7, .total = 12 } });
    const pure = ui.buildPackageLine(&ui.package_rows.items[0]);
    const pure_copy = try std.testing.allocator.dupe(u8, pure);
    defer std.testing.allocator.free(pure_copy);
    ui.renderStyledPackageLine(pure_copy);
    const styled = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[2m•\x1b[22m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[2m7") == null);
    var stripped: [512]u8 = undefined;
    var stripped_writer = std.Io.Writer.fixed(&stripped);
    try stripRendererAnsi(&stripped_writer, styled);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "\r{s}", .{pure_copy});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, stripped_writer.buffered());
    try std.testing.expect(displayCells(pure_copy) <= 99);

    var ascii_output: [512]u8 = undefined;
    var ascii_writer = std.Io.Writer.fixed(&ascii_output);
    var ascii_ui = ProgressUi.init(&ascii_writer, true, std.testing.io, 100, null);
    defer ascii_ui.deinit();
    ascii_ui.glyph_mode = .ascii;
    ascii_ui.apply(.{ .package_inventory = .{ .task_id = "p", .name = "p", .detail = "1", .total_bytes = 12 } });
    ascii_ui.apply(.{ .task_state = .{ .task_id = "p", .revision = 1, .state = "downloading", .message = "download" } });
    ascii_ui.apply(.{ .bytes = .{ .task_id = "p", .label = "p", .done = 7, .total = 12 } });
    const ascii_pure = ascii_ui.buildPackageLine(&ascii_ui.package_rows.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, ascii_pure, "•") == null);
    ascii_ui.renderStyledPackageLine(ascii_pure);
    try std.testing.expect(std.mem.indexOf(u8, ascii_writer.buffered(), "\x1b[2m") == null);
}

test "structured status vocabulary and compact fallback stay one cell" {
    const cases = [_]struct { wire: []const u8, status: PackageStatus, unicode: []const u8, ascii: []const u8 }{
        .{ .wire = "queued", .status = .queued, .unicode = "·", .ascii = "o" },
        .{ .wire = "downloading", .status = .downloading, .unicode = " ", .ascii = " " },
        .{ .wire = "verifying", .status = .verifying, .unicode = "?", .ascii = "?" },
        .{ .wire = "extracting", .status = .extracting, .unicode = "↧", .ascii = "v" },
        .{ .wire = "preparing", .status = .preparing, .unicode = "o", .ascii = "o" },
        .{ .wire = "building", .status = .compiling, .unicode = "c", .ascii = "c" },
        .{ .wire = "linking", .status = .linking, .unicode = "↔", .ascii = "<" },
        .{ .wire = "materializing", .status = .materializing, .unicode = "*", .ascii = "*" },
        .{ .wire = "completed", .status = .ready, .unicode = "+", .ascii = "+" },
        .{ .wire = "failed", .status = .failed, .unicode = "x", .ascii = "x" },
        .{ .wire = "cancelled", .status = .cancelled, .unicode = "-", .ascii = "-" },
    };
    var bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 40, null);
    defer ui.deinit();
    for (cases) |case| {
        try std.testing.expectEqual(case.status, packageStatusForProtocol(case.wire));
        const row = ProgressUi.PackageRow{ .task_id = "p", .name = "p", .detail = "1", .state = packageStateForStatus(case.status), .status = case.status, .total = null, .seed = 0, .permutation = braillePermutation(0) };
        try std.testing.expectEqualStrings(case.unicode, ui.packageStatus(&row));
        try std.testing.expectEqual(@as(usize, 1), displayCells(case.unicode));
        ui.glyph_mode = .ascii;
        try std.testing.expectEqualStrings(case.ascii, ui.packageStatus(&row));
        try std.testing.expectEqual(@as(usize, 1), displayCells(case.ascii));
        ui.glyph_mode = .unicode;
    }
    try std.testing.expectEqual(PackageStatus.queued, packageStatusForProtocol("untrusted-producer-word"));
}

test "package status animates across spinner frames in normal and wide breakpoints" {
    var bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 80, null);
    defer ui.deinit();

    const row = ProgressUi.PackageRow{
        .task_id = "demo",
        .name = "demo",
        .detail = "1.0",
        .state = .active,
        .status = .downloading,
        .total = 100,
        .seed = 0,
        .permutation = braillePermutation(0),
    };

    ui.spinner_frame = 0;
    try std.testing.expectEqualStrings("⠋", ui.packageStatus(&row));
    ui.spinner_frame = 1;
    try std.testing.expectEqualStrings("⠙", ui.packageStatus(&row));
    ui.spinner_frame = 5;
    try std.testing.expectEqualStrings("⠴", ui.packageStatus(&row));
    ui.spinner_frame = 10;
    try std.testing.expectEqualStrings("⠋", ui.packageStatus(&row));

    ui.glyph_mode = .ascii;
    try std.testing.expectEqualStrings("*", ui.packageStatus(&row));
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

test "package visual seed is stable and artifact discriminator separates versions" {
    const first = packageSeed("realize:native:rocks:dkjson@2.8", "b3:one");
    try std.testing.expectEqual(first, packageSeed("realize:native:rocks:dkjson@2.8", "b3:one"));
    try std.testing.expect(first != packageSeed("realize:native:rocks:dkjson@2.9", "b3:one"));
    try std.testing.expect(first != packageSeed("realize:native:rocks:dkjson@2.8", "b3:two"));
    try std.testing.expect(!std.mem.eql(u8, &braillePermutation(first), &braillePermutation(packageSeed("other", "b3:one"))));
}

test "seeded braille masks are monotonic exact and clamp progress" {
    const widths = [_]usize{ 1, 3, 5, 7 };
    for (0..32) |seed_index| {
        const permutation = braillePermutation(@intCast(seed_index));
        for (widths) |width| {
            var previous: [7]u8 = .{ 0, 0, 0, 0, 0, 0, 0 };
            for ([_]u64{ 0, 1, 10, 25, 50, 75, 99, 100, 101 }) |done| {
                const masks = brailleDotMasks(permutation, width, done, 100);
                var count: usize = 0;
                for (masks[0..width], previous[0..width]) |mask, old| {
                    try std.testing.expect((old & ~mask) == 0);
                    count += @popCount(mask);
                }
                try std.testing.expectEqual(determinateDotCount(done, 100, width), count);
                previous = masks;
            }
            const full = brailleDotMasks(permutation, width, 999, 100);
            for (full[0..width]) |mask| try std.testing.expectEqual(@as(u8, 0xff), mask);
        }
    }
}

test "package breakpoint alone selects full braille geometry" {
    try std.testing.expectEqual(@as(usize, 3), packageLayout(59).progress_cells);
    try std.testing.expectEqual(@as(usize, 5), packageLayout(80).progress_cells);
    try std.testing.expectEqual(@as(usize, 7), packageLayout(100).progress_cells);
}

test "package layout is breakpoint fixed and resize only changes at breakpoint" {
    const compact = packageLayout(59);
    const normal = packageLayout(60);
    const wide = packageLayout(100);
    try std.testing.expectEqual(PackageBreakpoint.compact, compact.breakpoint);
    try std.testing.expectEqual(PackageBreakpoint.normal, normal.breakpoint);
    try std.testing.expectEqual(PackageBreakpoint.wide, wide.breakpoint);
    try std.testing.expectEqual(@as(usize, 3), compact.progress_cells);
    try std.testing.expectEqual(@as(usize, 5), normal.progress_cells);
    try std.testing.expectEqual(@as(usize, 7), wide.progress_cells);
    try std.testing.expectEqual(@as(usize, 34), normal.detail_start);
    try std.testing.expectEqual(normal.detail_start, 2 + normal.progress_cells + 1 + normal.name_cells + 2);
    // A cached normal layout survives an in-breakpoint terminal resize.
    var cached = packageLayout(80);
    if (packageLayout(99).breakpoint != cached.breakpoint) cached = packageLayout(99);
    try std.testing.expectEqual(@as(usize, 24), cached.name_cells);
}

test "package reducer sorts arbitrary arrivals and derives invariant aggregate counts" {
    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 100, null);
    defer ui.deinit();
    ui.apply(.{ .package_inventory = .{ .task_id = "z", .name = "zeta", .detail = "1", .discriminator = "z" } });
    ui.apply(.{ .package_inventory = .{ .task_id = "a", .name = "alpha", .detail = "1", .discriminator = "a", .reused = true } });
    ui.apply(.{ .package_inventory = .{ .task_id = "m", .name = "middle", .detail = "1", .discriminator = "m" } });
    ui.apply(.{ .task_state = .{ .task_id = "m", .revision = 2, .state = "failed", .message = "network" } });
    ui.apply(.{ .task_state = .{ .task_id = "z", .revision = 1, .state = "running", .message = "download" } });
    ui.apply(.{ .task_state = .{ .task_id = "z", .revision = 3, .state = "completed", .message = "done" } });
    try std.testing.expectEqualStrings("a", ui.package_rows.items[0].task_id);
    try std.testing.expectEqualStrings("m", ui.package_rows.items[1].task_id);
    try std.testing.expectEqualStrings("z", ui.package_rows.items[2].task_id);
    const counts = ui.packageCounts();
    try std.testing.expectEqual(@as(usize, 2), counts.ready);
    try std.testing.expectEqual(@as(usize, 1), counts.failed);
    try std.testing.expectEqual(@as(usize, 3), counts.total());
}

test "package rows keep fixed starts through progress updates and clamp unicode names" {
    var bytes: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 100, null);
    defer ui.deinit();
    ui.apply(.{ .package_inventory = .{ .task_id = "p", .name = "漢字-super-long-package-name", .detail = "1.0", .discriminator = "hash", .total_bytes = 1024 * 1024 } });
    ui.apply(.{ .task_state = .{ .task_id = "p", .revision = 1, .state = "downloading", .message = "downloading" } });
    const layout = ui.package_layout;
    for ([_]u64{ 1, 10, 25, 50, 75, 99, 100 }) |percent| {
        ui.apply(.{ .bytes = .{ .task_id = "p", .label = "ignored", .done = percent, .total = 100 } });
        const line = ui.buildPackageLine(&ui.package_rows.items[0]);
        var bounded: [512]u8 = undefined;
        var bounded_writer = std.Io.Writer.fixed(&bounded);
        try appendBounded(&bounded_writer, line, 100);
        try std.testing.expectEqualStrings(line, bounded_writer.buffered());
        // status/progress/name geometry is independent of the percentage.
        try std.testing.expectEqual(layout.detail_start, 2 + layout.progress_cells + 1 + layout.name_cells + 2);
        const name_start = std.mem.indexOf(u8, line, "漢字").?;
        try std.testing.expectEqual(@as(usize, 2 + layout.progress_cells + 1), displayCells(line[0..name_start]));
        // Wide uses byte detail rather than percentage; the fixed name padding
        // therefore leaves the calculated detail column intact for every
        // progress update.
        try std.testing.expect(std.mem.indexOf(u8, line, "/") != null);
    }
}

test "terminal package rows reject stale bytes and active byte counters are monotonic" {
    var output: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 100, null);
    defer ui.deinit();

    ui.apply(.{ .package_inventory = .{ .task_id = "completed", .name = "completed", .detail = "1", .total_bytes = 100 } });
    ui.apply(.{ .task_state = .{ .task_id = "completed", .revision = 1, .state = "completed", .message = "done" } });
    // A reliable completion may arrive before this older volatile callback.
    ui.apply(.{ .bytes = .{ .task_id = "completed", .label = "completed", .done = 50, .total = 100 } });
    const completed = &ui.package_rows.items[0];
    try std.testing.expectEqual(PackageState.ready, completed.state);
    try std.testing.expectEqual(@as(u64, 100), completed.done);
    try std.testing.expectEqual(@as(?u64, 100), completed.total);
    const completed_line = ui.buildPackageLine(completed);
    try std.testing.expect(std.mem.indexOf(u8, completed_line, "ready") != null);

    ui.apply(.{ .package_inventory = .{ .task_id = "active", .name = "active", .detail = "1" } });
    ui.apply(.{ .bytes = .{ .task_id = "active", .label = "active", .done = 75, .total = 100 } });
    // Both values are stale: done must not decrease and the first discovered
    // total remains the stable denominator for this concrete transfer.
    ui.apply(.{ .bytes = .{ .task_id = "active", .label = "active", .done = 25, .total = 50 } });
    const active = &ui.package_rows.items[0];
    try std.testing.expectEqual(PackageState.active, active.state);
    try std.testing.expectEqual(@as(u64, 75), active.done);
    try std.testing.expectEqual(@as(?u64, 100), active.total);
    // A later genuine advancement still moves forward while retaining that
    // stable total rather than adopting a reordered callback's denominator.
    ui.apply(.{ .bytes = .{ .task_id = "active", .label = "active", .done = 90, .total = 200 } });
    try std.testing.expectEqual(@as(u64, 90), active.done);
    try std.testing.expectEqual(@as(?u64, 100), active.total);
}

test "only attributed determinate bytes advance seeded package Braille rows" {
    var output: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 100, null);
    defer ui.deinit();

    const task_id = "realize:x86_64-linux-gnu:rocks:demo@1";
    const discriminator = "b3:demo";
    const seed = packageSeed(task_id, discriminator);
    ui.apply(.{ .package_inventory = .{
        .task_id = task_id,
        .name = "demo",
        .detail = "1",
        .discriminator = discriminator,
    } });
    ui.apply(.{ .task_state = .{ .task_id = task_id, .revision = 1, .state = "downloading", .message = "download" } });
    const row = &ui.package_rows.items[0];
    try std.testing.expectEqual(seed, row.seed);
    try std.testing.expectEqualDeep(braillePermutation(seed), row.permutation);

    // A legacy name-only event retains its global progress behavior but cannot
    // claim this concrete package row, even though the name is unique.
    ui.apply(.{ .bytes = .{ .label = "demo", .done = 50, .total = 100 } });
    try std.testing.expectEqual(@as(u64, 0), row.done);
    try std.testing.expectEqual(@as(?u64, null), row.total);
    try std.testing.expectEqual(@as(u64, 50), ui.dl_done);
    try std.testing.expectEqual(@as(?u64, 100), ui.dl_total);

    // Attribution alone is still indeterminate without a denominator.
    ui.apply(.{ .bytes = .{ .task_id = task_id, .label = "demo", .done = 60, .total = null } });
    try std.testing.expectEqual(@as(u64, 0), row.done);
    try std.testing.expectEqual(@as(?u64, null), row.total);

    // The real transfer callback advances the cached identity permutation.
    ui.apply(.{ .bytes = .{ .task_id = task_id, .label = "demo", .done = 80, .total = 100 } });
    const first_masks = brailleDotMasks(row.permutation, 7, row.done, row.total.?);
    try std.testing.expectEqual(@as(u64, 80), row.done);
    try std.testing.expectEqual(@as(?u64, 100), row.total);
    try std.testing.expectEqualDeep(braillePermutation(seed), row.permutation);

    // A reordered volatile callback cannot unfill cells or change the cached
    // denominator/permutation.
    ui.apply(.{ .bytes = .{ .task_id = task_id, .label = "demo", .done = 30, .total = 50 } });
    const reordered_masks = brailleDotMasks(row.permutation, 7, row.done, row.total.?);
    try std.testing.expectEqual(@as(u64, 80), row.done);
    try std.testing.expectEqual(@as(?u64, 100), row.total);
    for (first_masks, reordered_masks) |before, after| try std.testing.expect((before & ~after) == 0);

    ui.apply(.{ .task_state = .{ .task_id = task_id, .revision = 2, .state = "completed", .message = "ready" } });
    try std.testing.expectEqual(PackageState.ready, row.state);
    try std.testing.expectEqual(@as(u64, 100), row.done);
    var cells: [64]u8 = undefined;
    var cell_writer = std.Io.Writer.fixed(&cells);
    try ui.writePackageProgress(&cell_writer, row);
    try std.testing.expectEqualStrings("⣿⣿⣿⣿⣿⣿⣿", cell_writer.buffered());
}

test "package row golden reference" {
    var bytes: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 100, null);
    defer ui.deinit();
    ui.apply(.{ .package_inventory = .{ .task_id = "tiny", .name = "tiny", .detail = "1.0", .discriminator = "tiny", .total_bytes = 1 } });
    ui.apply(.{ .package_inventory = .{ .task_id = "huge", .name = "huge", .detail = "9.0", .discriminator = "huge", .total_bytes = 64 * 1024 * 1024 } });
    ui.apply(.{ .task_state = .{ .task_id = "tiny", .revision = 1, .state = "completed", .message = "done" } });
    ui.apply(.{ .task_state = .{ .task_id = "huge", .revision = 1, .state = "downloading", .message = "download" } });
    ui.apply(.{ .bytes = .{ .task_id = "huge", .label = "huge", .done = 32 * 1024 * 1024, .total = 64 * 1024 * 1024 } });
    const huge = ui.buildPackageLine(&ui.package_rows.items[0]);
    const huge_copy = try std.testing.allocator.dupe(u8, huge);
    defer std.testing.allocator.free(huge_copy);
    const tiny = ui.buildPackageLine(&ui.package_rows.items[1]);
    const tiny_copy = try std.testing.allocator.dupe(u8, tiny);
    defer std.testing.allocator.free(tiny_copy);
    try std.testing.expectEqualStrings("⠋ ⠦⢊⢎⠘⢷⠷⢞ huge                              •32.0 / •64.0 MiB", huge_copy);
    try std.testing.expectEqualStrings("+ ⣿⣿⣿⣿⣿⣿⣿ tiny                              ready", tiny_copy);

    var normal_bytes: [256]u8 = undefined;
    var normal_writer = std.Io.Writer.fixed(&normal_bytes);
    var normal_ui = ProgressUi.init(&normal_writer, false, std.testing.io, 80, null);
    defer normal_ui.deinit();
    normal_ui.apply(.{ .package_inventory = .{ .task_id = "normal", .name = "normal", .detail = "2.0", .discriminator = "normal" } });
    normal_ui.apply(.{ .task_state = .{ .task_id = "normal", .revision = 1, .state = "preparing", .message = "ignored" } });
    const normal = normal_ui.buildPackageLine(&normal_ui.package_rows.items[0]);
    const normal_copy = try std.testing.allocator.dupe(u8, normal);
    defer std.testing.allocator.free(normal_copy);
    try std.testing.expectEqualStrings("⠋ ⠀⠀⠀⠀⠀ normal                    preparing: normal@2.0", normal_copy);

    var compact_bytes: [128]u8 = undefined;
    var compact_writer = std.Io.Writer.fixed(&compact_bytes);
    var compact_ui = ProgressUi.init(&compact_writer, false, std.testing.io, 40, null);
    defer compact_ui.deinit();
    compact_ui.apply(.{ .package_inventory = .{ .task_id = "broken", .name = "broken-package", .detail = "3.0", .discriminator = "broken" } });
    compact_ui.apply(.{ .task_state = .{ .task_id = "broken", .revision = 1, .state = "failed", .message = "network" } });
    const compact = compact_ui.buildPackageLine(&compact_ui.package_rows.items[0]);
    const compact_copy = try std.testing.allocator.dupe(u8, compact);
    defer std.testing.allocator.free(compact_copy);
    try std.testing.expectEqualStrings("x ⠉⠀⠀ broken-pack…", compact_copy);

    var ascii_wide_bytes: [256]u8 = undefined;
    var ascii_wide_writer = std.Io.Writer.fixed(&ascii_wide_bytes);
    var ascii_wide_ui = ProgressUi.init(&ascii_wide_writer, false, std.testing.io, 100, null);
    defer ascii_wide_ui.deinit();
    ascii_wide_ui.glyph_mode = .ascii;
    ascii_wide_ui.apply(.{ .package_inventory = .{ .task_id = "tiny", .name = "tiny", .detail = "1.0", .total_bytes = 1 } });
    ascii_wide_ui.apply(.{ .task_state = .{ .task_id = "tiny", .revision = 1, .state = "completed", .message = "done" } });
    const ascii_wide = ascii_wide_ui.buildPackageLine(&ascii_wide_ui.package_rows.items[0]);
    const ascii_wide_copy = try std.testing.allocator.dupe(u8, ascii_wide);
    defer std.testing.allocator.free(ascii_wide_copy);
    try std.testing.expectEqualStrings("+ ####### tiny                              ready", ascii_wide_copy);

    var ascii_normal_bytes: [256]u8 = undefined;
    var ascii_normal_writer = std.Io.Writer.fixed(&ascii_normal_bytes);
    var ascii_normal_ui = ProgressUi.init(&ascii_normal_writer, false, std.testing.io, 80, null);
    defer ascii_normal_ui.deinit();
    ascii_normal_ui.glyph_mode = .ascii;
    ascii_normal_ui.apply(.{ .package_inventory = .{ .task_id = "normal", .name = "normal", .detail = "2.0" } });
    ascii_normal_ui.apply(.{ .task_state = .{ .task_id = "normal", .revision = 1, .state = "preparing", .message = "ignored" } });
    const ascii_normal = ascii_normal_ui.buildPackageLine(&ascii_normal_ui.package_rows.items[0]);
    const ascii_normal_copy = try std.testing.allocator.dupe(u8, ascii_normal);
    defer std.testing.allocator.free(ascii_normal_copy);
    try std.testing.expectEqualStrings("* ..... normal                    preparing: normal@2.0", ascii_normal_copy);

    var ascii_compact_bytes: [128]u8 = undefined;
    var ascii_compact_writer = std.Io.Writer.fixed(&ascii_compact_bytes);
    var ascii_compact_ui = ProgressUi.init(&ascii_compact_writer, false, std.testing.io, 40, null);
    defer ascii_compact_ui.deinit();
    ascii_compact_ui.glyph_mode = .ascii;
    ascii_compact_ui.apply(.{ .package_inventory = .{ .task_id = "broken", .name = "broken-package", .detail = "3.0" } });
    ascii_compact_ui.apply(.{ .task_state = .{ .task_id = "broken", .revision = 1, .state = "failed", .message = "network" } });
    const ascii_compact = ascii_compact_ui.buildPackageLine(&ascii_compact_ui.package_rows.items[0]);
    const ascii_compact_copy = try std.testing.allocator.dupe(u8, ascii_compact);
    defer std.testing.allocator.free(ascii_compact_copy);
    try std.testing.expectEqualStrings("x #.. broken-pa...", ascii_compact_copy);
}

test "aggregate golden derives mixed ready active queued and failure states" {
    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 80, null);
    defer ui.deinit();
    ui.apply(.{ .package_inventory = .{ .task_id = "ready", .name = "ready", .detail = "1", .reused = true } });
    ui.apply(.{ .package_inventory = .{ .task_id = "active", .name = "active", .detail = "1" } });
    ui.apply(.{ .package_inventory = .{ .task_id = "queued", .name = "queued", .detail = "1" } });
    ui.apply(.{ .package_inventory = .{ .task_id = "failed", .name = "failed", .detail = "1" } });
    ui.apply(.{ .task_state = .{ .task_id = "active", .revision = 1, .state = "building", .message = "build" } });
    ui.apply(.{ .task_state = .{ .task_id = "failed", .revision = 1, .state = "failed", .message = "network" } });
    const counts = ui.packageCounts();
    var summary: [128]u8 = undefined;
    var summary_writer = std.Io.Writer.fixed(&summary);
    try writePackageSummary(&summary_writer, counts, .unicode);
    try std.testing.expectEqualStrings(
        "Installing 4 packages · 1 ready, 1 active, 1 failed",
        summary_writer.buffered(),
    );
    // A terminal update is idempotent and counters are never independently
    // incremented, so stale/concurrent arrivals cannot inflate the total.
    ui.apply(.{ .task_state = .{ .task_id = "failed", .revision = 1, .state = "running", .message = "stale" } });
    try std.testing.expectEqual(@as(usize, 4), ui.packageCounts().total());
}

test "reliable lane retains more than ring capacity inventory and terminal states" {
    var queue = try ProgressQueue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit(std.testing.allocator);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Interleave enough volatile bytes to overwrite the 256-cell ring. Every
    // inventory and terminal lifecycle event must still reach the reducer.
    for (0..300) |index| {
        const id = try std.fmt.allocPrint(allocator, "replay:native:rocks:pkg{d}@1", .{index});
        queue.send(.{ .package_inventory = .{ .task_id = id, .name = id, .detail = "1", .discriminator = id } });
        queue.send(.{ .bytes = .{ .label = "volatile", .done = index, .total = null } });
        queue.send(.{ .task_state = .{ .task_id = id, .revision = 1, .state = "completed", .message = "done" } });
    }
    var output: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 80, null);
    defer ui.deinit();
    while (queue.tryRecv()) |event| ui.apply(event);
    const counts = ui.packageCounts();
    try std.testing.expectEqual(@as(usize, 300), counts.total());
    try std.testing.expectEqual(@as(usize, 300), counts.ready);
    try std.testing.expectEqualStrings("replay:native:rocks:pkg0@1", ui.package_rows.items[0].task_id);
    try std.testing.expectEqualStrings("replay:native:rocks:pkg9@1", ui.package_rows.items[299].task_id);
}

test "queue owns stack-backed reliable lifecycle payloads" {
    var queue = try ProgressQueue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit(std.testing.allocator);

    {
        var task_id = [_]u8{ 'r', 't', '-', 'o', 'n', 'e' };
        var name = [_]u8{ 'l', 'u', 'a' };
        var detail = [_]u8{ '5', '.', '4' };
        var state = [_]u8{ 'r', 'u', 'n', 'n', 'i', 'n', 'g' };
        queue.send(.{ .package_inventory = .{
            .task_id = &task_id,
            .name = &name,
            .detail = &detail,
            .discriminator = "b3:runtime",
        } });
        queue.send(.{ .task_state = .{
            .task_id = &task_id,
            .revision = 1,
            .state = &state,
            .message = "runtime materializing",
        } });
        @memset(&task_id, 'x');
        @memset(&name, 'x');
        @memset(&detail, 'x');
        @memset(&state, 'x');
    }

    const inventory_event = queue.tryRecv().?;
    switch (inventory_event) {
        .package_inventory => |inventory| {
            try std.testing.expectEqualStrings("rt-one", inventory.task_id);
            try std.testing.expectEqualStrings("lua", inventory.name);
            try std.testing.expectEqualStrings("5.4", inventory.detail);
        },
        else => try std.testing.expect(false),
    }
    const state_event = queue.tryRecv().?;
    switch (state_event) {
        .task_state => |update| {
            try std.testing.expectEqualStrings("rt-one", update.task_id);
            try std.testing.expectEqualStrings("running", update.state);
        },
        else => try std.testing.expect(false),
    }
}

test "volatile payload ownership stays bounded across ring overwrite and drain" {
    var queue = try ProgressQueue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit(std.testing.allocator);
    var label: [512]u8 = undefined;
    @memset(&label, 'p');

    for (0..(ProgressQueue.default_capacity * 8)) |index| {
        queue.send(.{ .bytes = .{
            .task_id = "task",
            .label = &label,
            .done = index,
            .total = null,
        } });
    }
    // The ring retains exactly its capacity, not every overwritten callback.
    try std.testing.expectEqual(
        ProgressQueue.default_capacity * ("task".len + label.len),
        queue.volatile_payload_bytes,
    );
    try std.testing.expectEqual(@as(usize, 0), queue.reliable_payloads.items.len);

    while (queue.tryRecv()) |_| {}
    // The final empty receive releases the last in-flight hand-off.
    try std.testing.expectEqual(@as(usize, 0), queue.volatile_payload_bytes);
}

test "cached multi-package completion pins a newline-delimited durable frame" {
    var output: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var ui = ProgressUi.init(&writer, true, std.testing.io, 80, null);
    defer ui.deinit();
    ui.apply(.{ .package_inventory = .{ .task_id = "a", .name = "a", .detail = "1", .reused = true } });
    try std.testing.expectEqual(ProgressUi.CompletionDisposition.transient_clear, ui.completionDisposition());
    ui.apply(.{ .package_inventory = .{ .task_id = "b", .name = "b", .detail = "1", .reused = true } });
    ui.apply(.{ .package_inventory = .{ .task_id = "c", .name = "c", .detail = "1", .reused = true } });
    // The completion path writes this visible frame, then a newline, then the
    // ordinary empty-line clear. The newline prevents that control from
    // erasing the aggregate frame or contaminating the subsequent shell line.
    try std.testing.expectEqual(ProgressUi.CompletionDisposition.durable_package_frame, ui.completionDisposition());
    ui.pinDurablePackageCompletion();
    ui.renderFinal();
    const transcript = writer.buffered();
    const summary = std.mem.indexOf(u8, transcript, "Installing 3 packages · 3 ready") orelse return error.TestUnexpectedResult;
    const newline = std.mem.indexOfPos(u8, transcript, summary, "\n") orelse return error.TestUnexpectedResult;
    const erase = std.mem.indexOfPos(u8, transcript, newline, "\x1b[2K\r") orelse return error.TestUnexpectedResult;
    try std.testing.expect(erase > newline);

    // A non-cached state keeps the ordinary transient cleanup behavior.
    var transient_output: [64]u8 = undefined;
    var transient_writer = std.Io.Writer.fixed(&transient_output);
    var transient = ProgressUi.init(&transient_writer, true, std.testing.io, 80, null);
    defer transient.deinit();
    transient.apply(.{ .package_inventory = .{ .task_id = "a", .name = "a", .detail = "1", .reused = true } });
    transient.apply(.{ .package_inventory = .{ .task_id = "b", .name = "b", .detail = "1", .reused = true } });
    transient.apply(.{ .package_inventory = .{ .task_id = "c", .name = "c", .detail = "1", .reused = true } });
    transient.apply(.{ .task_state = .{ .task_id = "b", .revision = 1, .state = "running", .message = "not cached" } });
    try std.testing.expectEqual(ProgressUi.CompletionDisposition.transient_clear, transient.completionDisposition());
}

test "later runtime phase inventory extends the truthful aggregate denominator" {
    var output: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 80, null);
    defer ui.deinit();

    // The selected runtime phase completes before a lazy isolated-tool phase
    // can be discovered. The aggregate grows only once that second concrete
    // remote materialization is known, rather than pre-counting a store hit.
    ui.apply(.{ .package_inventory = .{ .task_id = "realize:target:runtime:lua@5.4", .name = "lua", .detail = "5.4 (selected runtime)" } });
    ui.apply(.{ .task_state = .{ .task_id = "realize:target:runtime:lua@5.4", .revision = 1, .state = "completed", .message = "done" } });
    try std.testing.expectEqual(@as(usize, 1), ui.packageCounts().total());
    try std.testing.expectEqual(@as(usize, 1), ui.packageCounts().ready);

    ui.apply(.{ .package_inventory = .{ .task_id = "realize:host:runtime-isolated-tool:luajit@2.1", .name = "luajit", .detail = "2.1 (isolated tool runtime)" } });
    const counts = ui.packageCounts();
    try std.testing.expectEqual(@as(usize, 2), counts.total());
    try std.testing.expectEqual(@as(usize, 1), counts.ready);
    try std.testing.expectEqual(@as(usize, 1), counts.queued);
}

test "fail-fast preserves the failing package and cancels only unfinished peers" {
    var output: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 80, null);
    defer ui.deinit();
    for ([_][]const u8{ "failed", "active", "queued" }) |task_id| {
        ui.apply(.{ .package_inventory = .{ .task_id = task_id, .name = task_id, .detail = "1" } });
    }
    ui.apply(.{ .task_state = .{ .task_id = "failed", .revision = 1, .state = "running", .message = "started" } });
    ui.apply(.{ .task_state = .{ .task_id = "active", .revision = 1, .state = "running", .message = "started" } });
    ui.apply(.{ .task_state = .{ .task_id = "failed", .revision = 2, .state = "failed", .message = "network" } });
    ui.reconcileIncompletePackages();
    const counts = ui.packageCounts();
    try std.testing.expectEqual(@as(usize, 1), counts.failed);
    try std.testing.expectEqual(@as(usize, 2), counts.cancelled);
    try std.testing.expectEqual(@as(usize, 3), counts.total());
}

test "locked replay uses one terminal package record and failure reconciles unfinished work" {
    var output: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 80, null);
    defer ui.deinit();
    // Replay inventory is the only inventory for this logical package; a
    // terminal update targets that same canonical replay identity.
    ui.apply(.{ .package_inventory = .{ .task_id = "replay:native:rocks:demo@1", .name = "demo", .detail = "1", .discriminator = "b3:demo" } });
    ui.apply(.{ .task_state = .{ .task_id = "replay:native:rocks:demo@1", .revision = 1, .state = "completed", .message = "done" } });
    try std.testing.expectEqual(@as(usize, 1), ui.packageCounts().total());
    try std.testing.expectEqual(@as(usize, 1), ui.packageCounts().ready);

    ui.apply(.{ .package_inventory = .{ .task_id = "replay:native:rocks:later@1", .name = "later", .detail = "1" } });
    ui.apply(.{ .package_inventory = .{ .task_id = "replay:native:rocks:queued@1", .name = "queued", .detail = "1" } });
    ui.apply(.{ .task_state = .{ .task_id = "replay:native:rocks:later@1", .revision = 1, .state = "running", .message = "work" } });
    ui.reconcileIncompletePackages();
    const counts = ui.packageCounts();
    try std.testing.expectEqual(@as(usize, 1), counts.ready);
    try std.testing.expectEqual(@as(usize, 2), counts.cancelled);
    try std.testing.expectEqual(@as(usize, 3), counts.total());
}

test "indeterminate active package does not duplicate spinner" {
    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 80, null);
    defer ui.deinit();

    ui.apply(.{ .package_inventory = .{ .task_id = "comp", .name = "comp", .detail = "1.0" } });
    ui.apply(.{ .task_state = .{ .task_id = "comp", .revision = 1, .state = "compiling", .message = "build" } });

    const line = ui.buildPackageLine(&ui.package_rows.items[0]);
    try std.testing.expectEqualStrings("⠋ ⠀⠀⠀⠀⠀ comp                      compiling: comp@1.0", line);
}

test "wide mode detail shows status words for non-downloading and ready states" {
    var bytes: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 100, null);
    defer ui.deinit();

    ui.apply(.{ .package_inventory = .{ .task_id = "pkg", .name = "pkg", .detail = "1.0", .total_bytes = 1000 } });

    // When compiling, even with total_bytes set, wide detail shows compiling
    ui.apply(.{ .task_state = .{ .task_id = "pkg", .revision = 1, .state = "compiling", .message = "build" } });
    const compiling_line = ui.buildPackageLine(&ui.package_rows.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, compiling_line, "compiling") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiling_line, "/") == null);

    // When downloading with total, wide detail shows byte counters
    ui.apply(.{ .task_state = .{ .task_id = "pkg", .revision = 2, .state = "downloading", .message = "fetch" } });
    ui.apply(.{ .bytes = .{ .task_id = "pkg", .label = "pkg", .done = 500, .total = 1000 } });
    const dl_line = ui.buildPackageLine(&ui.package_rows.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, dl_line, "/") != null);

    // When completed (ready), wide detail shows ready
    ui.apply(.{ .task_state = .{ .task_id = "pkg", .revision = 3, .state = "completed", .message = "done" } });
    const ready_line = ui.buildPackageLine(&ui.package_rows.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, ready_line, "ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, ready_line, "/") == null);
}

test "renderPackageRows partitions active rows first respecting max_visible_rows" {
    var bytes: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var ui = ProgressUi.init(&writer, true, std.testing.io, 80, null);
    defer ui.deinit();
    ui.max_visible_rows = 3;

    // Add 5 packages: a (ready), b (active), c (queued), d (active), e (queued)
    ui.apply(.{ .package_inventory = .{ .task_id = "a", .name = "a", .detail = "1" } });
    ui.apply(.{ .package_inventory = .{ .task_id = "b", .name = "b", .detail = "1" } });
    ui.apply(.{ .package_inventory = .{ .task_id = "c", .name = "c", .detail = "1" } });
    ui.apply(.{ .package_inventory = .{ .task_id = "d", .name = "d", .detail = "1" } });
    ui.apply(.{ .package_inventory = .{ .task_id = "e", .name = "e", .detail = "1" } });

    ui.apply(.{ .task_state = .{ .task_id = "a", .revision = 1, .state = "completed", .message = "done" } });
    ui.apply(.{ .task_state = .{ .task_id = "b", .revision = 1, .state = "compiling", .message = "build" } });
    ui.apply(.{ .task_state = .{ .task_id = "d", .revision = 1, .state = "downloading", .message = "fetch" } });

    ui.render();
    const transcript = writer.buffered();
    const b_pos = std.mem.indexOf(u8, transcript, "b ") orelse return error.TestUnexpectedResult;
    const d_pos = std.mem.indexOf(u8, transcript, "d ") orelse return error.TestUnexpectedResult;
    const c_pos = std.mem.indexOf(u8, transcript, "c ") orelse return error.TestUnexpectedResult;
    try std.testing.expect(b_pos < d_pos);
    try std.testing.expect(d_pos < c_pos);
    _ = std.mem.indexOf(u8, transcript, "… 2 more packages") orelse return error.TestUnexpectedResult;
}

test "apply deduplicates phase_done and resets rendered_lines on durable print" {
    var bytes: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 80, null);
    defer ui.deinit();

    ui.apply(.{ .phase_done = "LuaRocks manifest synced" });
    ui.apply(.{ .phase_done = "LuaRocks manifest synced" }); // Duplicate!
    try std.testing.expectEqualStrings("LuaRocks manifest synced\n", writer.buffered());
}

test "cursor is hidden at TTY init and restored at deinit and renderFinal" {
    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    {
        var ui = ProgressUi.init(&writer, true, std.testing.io, 80, null);
        try std.testing.expectEqualStrings("\x1b[?25l", writer.buffered());
        ui.renderFinal();
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[?25h") != null);
    }
}

test "progress keeps identical package versions in distinct task scopes separate" {
    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 80, null);
    defer ui.deinit();

    const selected = "realize:native:runtime-selected:lua@5.4.7";
    const parser = "realize:native:runtime-host-parser:lua@5.4.7";
    ui.apply(.{ .package_inventory = .{ .task_id = selected, .name = "lua", .detail = "5.4.7" } });
    ui.apply(.{ .package_inventory = .{ .task_id = parser, .name = "lua", .detail = "5.4.7" } });
    ui.apply(.{ .task_state = .{ .task_id = selected, .revision = 1, .state = "completed", .message = "selected done" } });
    ui.apply(.{ .task_state = .{ .task_id = parser, .revision = 1, .state = "downloading", .message = "parser fetch" } });

    const counts = ui.packageCounts();
    try std.testing.expectEqual(@as(usize, 2), counts.total());
    for (ui.package_rows.items) |row| {
        if (std.mem.eql(u8, row.task_id, selected)) {
            try std.testing.expectEqual(PackageState.ready, row.state);
        } else if (std.mem.eql(u8, row.task_id, parser)) {
            try std.testing.expectEqual(PackageState.active, row.state);
        } else return error.TestUnexpectedResult;
    }
}

test "terminalRows queries LINES env and clamps max_visible_rows" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("LINES", "40");

    const rows = terminalRows(std.testing.io, &env_map, false);
    try std.testing.expectEqual(@as(usize, 40), rows);

    var bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var ui = ProgressUi.init(&writer, false, std.testing.io, 80, &env_map);
    defer ui.deinit();
    try std.testing.expectEqual(@as(usize, 40), ui.rows);
    try std.testing.expectEqual(@as(usize, 25), ui.max_visible_rows);
}
