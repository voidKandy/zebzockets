const std = @import("std");
const zebzockets = @import("zebzockets");
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
    const args = zebzockets.cli.CliArgs.parse() orelse return;
    const peer = try std.net.Address.parseIp4(args.info.host, args.info.port);
    const stream = try net.tcpConnectToAddress(peer);
    defer stream.close();
    print("Connecting to {}\n", .{peer});

    const headers: [3]zebzockets.ExpectedHeader =
        .{
        zebzockets.ExpectedHeader.from(zebzockets.ExpectedHeader.Key, "dGhlIHNhbXBsZSBub25jZQ=="),
        zebzockets.ExpectedHeader.from(zebzockets.ExpectedHeader.Version, "13"),
        zebzockets.ExpectedHeader.from(zebzockets.ExpectedHeader.Protocol, "chat, superchat"),
    };
    const uri = try zebzockets.WsUri.from_str("ws://127.0.0.1/chat");
    var handshake = try ClientHandshake.init_with_headers(uri, &headers, allocator);
    defer handshake.deinit();
    const body =
        try handshake.body();
    defer body.deinit();
    var writer = stream.writer();
    const size = try writer.write(body.items);
    print("Sending '{s}' to peer, total written: {d} bytes\n", .{ body.items, size });
    // Or just using `writer.writeAll`
    // try writer.writeAll("hello zig");
}

pub const ClientHandshake = struct {
    headers: zebzockets.HeaderMap,
    uri: zebzockets.WsUri,
    arena: std.heap.ArenaAllocator,
    const Self = @This();

    pub fn init(uri: zebzockets.WsUri, allocator: std.mem.Allocator) !Self {
        var arena = std.heap.ArenaAllocator.init(allocator);
        var headers = zebzockets.HeaderMap.init(arena.allocator());
        try headers.put("Upgrade", "websocket");
        try headers.put("Connection", "Upgrade");

        const host_value = try std.fmt.allocPrint(arena.allocator(), "{s}:{s}", .{ uri.host, uri.port });
        const host_header = zebzockets.ExpectedHeader.from(zebzockets.ExpectedHeader.Host, host_value);
        try host_header.put(&headers);
        return Self{
            .headers = headers,
            .uri = uri,
            .arena = arena,
        };
    }
    pub fn init_with_headers(uri: zebzockets.WsUri, insert_headers: []const zebzockets.ExpectedHeader, allocator: std.mem.Allocator) !Self {
        var self = try Self.init(uri, allocator);
        for (insert_headers) |h| {
            try h.put(&self.headers);
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
        return;
    }

    /// converts object into a request body that can be sent
    pub fn body(self: *Self) !std.ArrayList(u8) {
        var buffer = std.ArrayList(u8).init(self.arena.allocator());
        try buffer.appendSlice("GET ");
        try buffer.appendSlice(self.uri.path);
        try buffer.appendSlice(" HTTP/1.1 \r\n");
        var headers_iter =
            self.headers.iterator();
        while (headers_iter.next()) |entry| {
            try buffer.appendSlice(entry.key_ptr.*);
            try buffer.appendSlice(": ");
            try buffer.appendSlice(entry.value_ptr.*);
            try buffer.appendSlice("\r\n");
        }
        return buffer;
    }
};

test "client handshake building" {
    const allocator = std.testing.allocator;
    const headers: [3]zebzockets.ExpectedHeader =
        .{
        zebzockets.ExpectedHeader.from(zebzockets.ExpectedHeader.Key, "dGhlIHNhbXBsZSBub25jZQ=="),
        zebzockets.ExpectedHeader.from(zebzockets.ExpectedHeader.Version, "13"),
        zebzockets.ExpectedHeader.from(zebzockets.ExpectedHeader.Protocol, "chat, superchat"),
    };
    const uri = try zebzockets.WsUri.from_str("ws://127.0.0.1/chat");
    var handshake = try ClientHandshake.init_with_headers(uri, &headers, allocator);
    defer handshake.deinit();
    const body = try handshake.body();
    defer body.deinit();
    std.debug.print("BODY: {s}\n", .{body.items});
    std.debug.print("CLIENT HANDSHAKE BUILDING PASSED\n", .{});
}
