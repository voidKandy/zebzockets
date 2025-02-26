const std = @import("std");
const websockets = @import("websockets");
const net = std.net;
const print = std.debug.print;
const assert = std.debug.assert;

const usage =
    \\ usage: <binary-name> [<host>:<port>]|--help
    \\ To use default host and port values simply pass ':'
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = std.process.args();
    assert(args.skip());

    const first_arg = args.next() orelse {
        print("{s}", .{usage});
        return;
    };

    if (std.mem.eql(u8, "--help", first_arg)) {
        print("{s}", .{usage});
        return;
    }
    const info = websockets.connection_information(first_arg);
    const peer = try std.net.Address.parseIp4(info.host, info.port);
    // Connect to peer
    const stream = try net.tcpConnectToAddress(peer);
    defer stream.close();
    print("Connecting to {}\n", .{peer});

    // Sending data to peer
    var handshake = try Handshake.init("/chat", "dGhlIHNhbXBsZSBub25jZQ==", "127.0.0.1", "http://www.example.com", allocator);
    defer handshake.deinit();
    const body =
        try handshake.body();
    defer body.deinit();
    var writer = stream.writer();
    const size = try writer.write(body.items);
    print("Sending '{s}' to peer, total written: {d} bytes\n", .{ body, size });
    // Or just using `writer.writeAll`
    // try writer.writeAll("hello zig");
}
const Handshake = struct {
    headers: std.StringHashMap([]const u8),
    endpoint: []const u8,
    allocator: std.mem.Allocator,
    const Self = @This();

    fn init(endpoint: []const u8, key: []const u8, host: []const u8, origin: []const u8, allocator: std.mem.Allocator) !Self {
        var headers = std.StringHashMap([]const u8).init(allocator);
        try headers.put("Host", host);
        try headers.put("Origin", origin);
        try headers.put("Sec-WebSocket-Key", key);
        try headers.put("Upgrade", "websocket");
        try headers.put("Connection", "Upgrade");
        // this might need to be configurable
        try headers.put("Sec-WebSocket-Version", "13");
        try headers.put("Sec-WebSocket-Protocol", "chat, superchat");
        return Handshake{
            .headers = headers,
            .endpoint = endpoint,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Self) void {
        self.headers.deinit();
        return;
    }

    /// converts object into a request body that can be sent
    fn body(self: *Self) !std.ArrayList(u8) {
        var buffer = std.ArrayList(u8).init(self.allocator);
        try buffer.appendSlice("GET ");
        try buffer.appendSlice(self.endpoint);
        try buffer.appendSlice("HTTP/1.1 ");
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

test "header building" {
    const allocator = std.testing.allocator;
    var handshake = try Handshake.init("/chat", "dGhlIHNhbXBsZSBub25jZQ==", "127.0.0.1", "http://www.example.com", allocator);
    defer handshake.deinit();
    const body = try handshake.body();
    defer body.deinit();
    print("BODY: {s}\n", .{body.items});
}
