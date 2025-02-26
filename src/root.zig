//! Shared library for client and server

const std = @import("std");
const testing = std.testing;

const default_host = "127.0.0.1";
const default_port = 6000;

pub const ConnectionInfo = struct {
    host: []const u8,
    port: u16,
};
/// Assumes the `arg` passed is formatted as follows:
/// \<host\>:\<port\>
/// If either `host` or `port` are missing, replaces them with default values
pub fn connection_information(arg: []const u8) ConnectionInfo {
    var split = std.mem.split(u8, arg, ":");
    const host = blk: {
        const first = split.first();
        if (first.len == 0) {
            break :blk default_host;
        } else {
            break :blk first;
        }
    };
    const port: u16 = blk: {
        const next = split.next() orelse break :blk default_port;
        if (next.len != 0) {
            break :blk std.fmt.parseInt(u16, next, 10) catch |err| {
                std.debug.panic("could not parse port {s} to int: {any}\n", .{ next, err });
            };
        } else {
            break :blk default_port;
        }
    };

    return .{ .host = host, .port = port };
    // return try std.net.Address.parseIp4(host, port);
}

pub const ClientHandshake = struct {
    pub const Config = struct {
        /// Base-64 encoded string that the server concatenates with a Globally Unique Identifier
        /// This concatenated string is then Sha-1 hashed, Base-64 encoded and returned to the client
        key: []const u8,
        endpoint: []const u8,
        host: []const u8,
        /// Used to protect against unauthorized cross-origin use of a WebSocket server by scripts using the WebSocket API in a web browser.
        /// This header field is sent by browser clients; for non-browser clients, this header field may be sent if it makes sense in the context of those clients.
        origin: ?[]const u8,
    };
    const HeaderMap =
        std.StringHashMap([]const u8);
    headers: HeaderMap,
    endpoint: []const u8,
    allocator: std.mem.Allocator,
    const Self = @This();

    pub fn init(config: Self.Config, allocator: std.mem.Allocator) !Self {
        var headers = Self.HeaderMap.init(allocator);
        try headers.put("Host", config.host);
        if (config.origin) |origin| {
            try headers.put("Origin", origin);
        }
        try headers.put("Sec-WebSocket-Key", config.key);
        try headers.put("Upgrade", "websocket");
        try headers.put("Connection", "Upgrade");
        // this might need to be configurable
        try headers.put("Sec-WebSocket-Version", "13");
        try headers.put("Sec-WebSocket-Protocol", "chat, superchat");
        return Self{
            .headers = headers,
            .endpoint = config.endpoint,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.headers.deinit();
        return;
    }

    /// converts object into a request body that can be sent
    pub fn body(self: *Self) !std.ArrayList(u8) {
        var buffer = std.ArrayList(u8).init(self.allocator);
        try buffer.appendSlice("GET ");
        try buffer.appendSlice(self.endpoint);
        try buffer.appendSlice(" HTTP/1.1 ");
        var headers_iter =
            self.headers.iterator();
        while (headers_iter.next()) |entry| {
            try buffer.appendSlice(entry.key_ptr.*);
            try buffer.appendSlice(": ");
            try buffer.appendSlice(entry.value_ptr.*);
            try buffer.append(' ');
        }
        try buffer.appendSlice("\r\n");
        return buffer;
    }
};

test "client handshake building" {
    const allocator = std.testing.allocator;
    const handshake_cfg = ClientHandshake.Config{ .key = "dGhlIHNhbXBsZSBub25jZQ==", .endpoint = "/chat", .host = "127.0.0.1", .origin = null };
    var handshake = try ClientHandshake.init(handshake_cfg, allocator);
    defer handshake.deinit();
    const body = try handshake.body();
    defer body.deinit();
    std.debug.print("BODY: {s}\n", .{body.items});
}
