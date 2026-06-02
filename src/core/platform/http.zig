const std = @import("std");
const fs = @import("fs.zig");

pub const HttpConfig = struct {
    timeout_ms: u32 = 30_000,
};

pub fn get_http_config(allocator: std.mem.Allocator, env_map: *std.process.Environ.Map, io: std.Io) HttpConfig {
    const net_cfg = fs.get_network_config(allocator, env_map, io);
    var cfg = HttpConfig{
        .timeout_ms = net_cfg.timeout * 1000,
    };
    if (env_map.get("MOONSTONE_HTTP_TIMEOUT_MS")) |val| {
        cfg.timeout_ms = std.fmt.parseInt(u32, val, 10) catch cfg.timeout_ms;
    }
    return cfg;
}

pub const FetchResponse = struct {
    status: std.http.Status,
    body: []u8,
};

fn ensureCaBundle(client: *std.http.Client) !void {
    if (std.http.Client.disable_tls) return;
    const io = client.io;
    {
        try client.ca_bundle_lock.lockShared(io);
        defer client.ca_bundle_lock.unlockShared(io);
        if (client.now != null) return;
    }
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(client.allocator);
    const now = std.Io.Clock.real.now(io);
    bundle.rescan(client.allocator, io, now) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return error.CertificateBundleLoadFailure,
    };
    try client.ca_bundle_lock.lock(io);
    defer client.ca_bundle_lock.unlock(io);
    client.now = now;
    std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
}

fn doFetch(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    extra_headers: ?[]const std.http.Header,
    timeout_ms: u32,
) !FetchResponse {
    const uri = try std.Uri.parse(url);
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedUriScheme;

    if (protocol == .tls) {
        try ensureCaBundle(client);
    }

    var host_name_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_name = try uri.getHost(&host_name_buffer);
    const port = uri.port orelse switch (protocol) {
        .plain => @as(u16, 80),
        .tls => @as(u16, 443),
    };

    const conn = try client.connectTcpOptions(.{
        .host = host_name,
        .port = port,
        .protocol = protocol,
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMicroseconds(@as(i64, timeout_ms) * 1000),
            .clock = .real,
        } },
    });

    var req = try client.request(.GET, uri, .{
        .connection = conn,
        .extra_headers = extra_headers orelse &.{},
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [4096]u8 = undefined;
    var resp = try req.receiveHead(&redirect_buf);

    const decompress_buffer: []u8 = switch (resp.head.content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (resp.head.content_encoding != .identity) allocator.free(decompress_buffer);

    var transfer_buf: [8192]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var reader = resp.readerDecompressing(&transfer_buf, &decompress, decompress_buffer);
    const body = try reader.allocRemaining(allocator, std.Io.Limit.limited(50 * 1024 * 1024));

    return .{
        .status = resp.head.status,
        .body = body,
    };
}

pub fn fetchGet(allocator: std.mem.Allocator, io: std.Io, url: []const u8, extra_headers: ?[]const std.http.Header, timeout_ms: u32) !FetchResponse {
    var client = std.http.Client{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();
    return doFetch(allocator, &client, url, extra_headers, timeout_ms);
}

pub fn fetchGetWithClient(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, extra_headers: ?[]const std.http.Header, timeout_ms: u32) !FetchResponse {
    return doFetch(allocator, client, url, extra_headers, timeout_ms);
}

pub fn fetchGetBody(allocator: std.mem.Allocator, io: std.Io, url: []const u8, extra_headers: ?[]const std.http.Header, timeout_ms: u32) ![]u8 {
    const resp = try fetchGet(allocator, io, url, extra_headers, timeout_ms);
    if (resp.status != .ok) {
        allocator.free(resp.body);
        return error.HttpError;
    }
    return resp.body;
}

pub fn fetchGetBodyWithClient(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, extra_headers: ?[]const std.http.Header, timeout_ms: u32) ![]u8 {
    const resp = try fetchGetWithClient(allocator, client, url, extra_headers, timeout_ms);
    if (resp.status != .ok) {
        allocator.free(resp.body);
        return error.HttpError;
    }
    return resp.body;
}
