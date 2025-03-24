const root = @import("../root.zig");
const std = @import("std");
const log = std.log;

pub const Handshake = struct {
    headers: root.HeaderMap,
    uri: root.WsUri,
    arena: std.heap.ArenaAllocator,
    const Self = @This();

    pub const Deserialized = struct {
        resource: []const u8,
        host: root.ExpectedHeader.Host,
        key: root.ExpectedHeader.Key,
        version: root.ExpectedHeader.Version,
        connection: root.ExpectedHeader.Connection,
        upgrade: root.ExpectedHeader.Upgrade,
        protocol: root.ExpectedHeader.Protocol,
        origin: ?root.ExpectedHeader.Origin,
        extensions: ?root.ExpectedHeader.Extensions,

        const Builder = struct { resource: ?[]const u8 = null, host: ?root.ExpectedHeader.Host = null, connection: ?root.ExpectedHeader.Connection = null, key: ?root.ExpectedHeader.Key = null, version: ?root.ExpectedHeader.Version = null, upgrade: ?root.ExpectedHeader.Upgrade = null, protocol: ?root.ExpectedHeader.Protocol = null, origin: ?root.ExpectedHeader.Origin = null, extensions: ?root.ExpectedHeader.Extensions = null };

        fn new() Builder {
            return Builder{};
        }

        fn build(builder: Builder) !Self.Deserialized {
            return Self.Deserialized{
                .resource = builder.resource orelse return error.MissingFieldResource,
                .host = builder.host orelse return error.MissingFieldHost,
                .key = builder.key orelse return error.MissingFieldKey,
                .version = builder.version orelse return error.MissingFieldVersion,
                .upgrade = builder.upgrade orelse return error.MissingFieldUpgrade,
                .protocol = builder.protocol orelse return error.MissingFieldProtocol,
                .connection = builder.connection orelse return error.MissingFieldConnection,
                .origin = builder.origin,
                .extensions = builder.extensions,
            };
        }
    };

    pub fn init(uri: root.WsUri, allocator: std.mem.Allocator) !Self {
        var arena = std.heap.ArenaAllocator.init(allocator);
        var headers = root.HeaderMap.init(arena.allocator());
        const v = root.ExpectedHeader{ .version = root.ExpectedHeader.VERSION };
        try v.put(&headers);
        const u = root.ExpectedHeader{ .upgrade = root.ExpectedHeader.UPGRADE };
        try u.put(&headers);
        const c = root.ExpectedHeader{ .connection = root.ExpectedHeader.CONNECTION };
        try c.put(&headers);

        const host_value = try std.fmt.allocPrint(arena.allocator(), "{s}:{s}", .{ uri.host, uri.port });
        const host_header = root.ExpectedHeader.from(root.ExpectedHeader.Host, host_value);
        try host_header.put(&headers);
        return Self{
            .headers = headers,
            .uri = uri,
            .arena = arena,
        };
    }
    pub fn init_with_headers(uri: root.WsUri, insert_headers: []const root.ExpectedHeader, allocator: std.mem.Allocator) !Self {
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

    pub fn try_from_bytes(msg: []u8) !Self.Deserialized {
        var lines = std.mem.splitScalar(u8, msg, '\n');

        const leading_line = lines.first();
        var leading_line_whitespace_split = std.mem.splitScalar(u8, leading_line, ' ');

        const method = root.Method.parse(leading_line_whitespace_split.first()) orelse return error.InvalidLeadingLine;
        if (method != root.Method.get) {
            log.err("Invalid method, got: {any}\n", .{method});
            return error.InvalidMethod;
        }
        const path: []const u8 = leading_line_whitespace_split.next() orelse {
            log.err("Did not get path\n", .{});
            return error.InvalidLeadingLine;
        };
        const http_version = leading_line_whitespace_split.next() orelse {
            log.err("Did not get http_version\n", .{});
            return error.InvalidLeadingLine;
        };

        log.info("Method: {any}\npath: {s}\nhttp_version: {s}\n", .{ method, path, http_version });

        var builder = Self.Deserialized.new();
        builder.resource = path;
        while (lines.next()) |line| {
            // log.warn("trying header from line: {s}\n", .{line});
            if (root.ExpectedHeader.try_from_str(line)) |header| {
                switch (header) {
                    .host => |i| builder.host = i,
                    .key => |i| builder.key = i,
                    .version => |i| builder.version = i,
                    .upgrade => |i| builder.upgrade = i,
                    .protocol => |i| builder.protocol = i,
                    .origin => |i| builder.origin = i,
                    .connection => |i| builder.connection = i,
                    .extensions => |i| builder.extensions = i,
                    else => |i| log.warn("ignoring header: {any}\n", .{i}),
                }
            }
        }
        return Self.Deserialized.build(builder);
    }
};

test "client handshake building" {
    const allocator = std.testing.allocator;
    const headers = [_]root.ExpectedHeader{
        root.ExpectedHeader.from(root.ExpectedHeader.Key, "dGhlIHNhbXBsZSBub25jZQ=="),
        root.ExpectedHeader.from(root.ExpectedHeader.Protocol, "chat, superchat"),
    };
    const uri = try root.WsUri.from_str("ws://127.0.0.1/chat");
    var handshake = try Handshake.init_with_headers(uri, &headers, allocator);
    defer handshake.deinit();
    const body = try handshake.body();
    defer body.deinit();
    std.debug.print("BODY: {s}\n", .{body.items});
}

test "ClientHandshake from message works" {
    const message_str =
        \\ GET /chat HTTP/1.1
        \\ Host: server.example.com
        \\ Upgrade: websocket
        \\ Connection: Upgrade
        \\ Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
        \\ Origin: http://example.com
        \\ Sec-WebSocket-Protocol: chat, superchat
        \\ Sec-WebSocket-Version: 13
    ;
    const message = std.mem.trim(u8, message_str, " \n");

    const allocator = std.testing.allocator;

    const msg = try allocator.alloc(u8, message.len);
    defer allocator.free(msg);
    @memcpy(msg, message);

    log.warn("getting handshake from:\n{s}\n", .{msg});
    const hs = try Handshake.try_from_bytes(msg);
    std.testing.expect(std.mem.eql(u8, hs.host.val, "server.example.com")) catch |err| log.warn("failed host check:\n{any}\nval: {s}\n", .{ err, hs.host.val });
    std.testing.expect(std.mem.eql(u8, hs.upgrade.val, "websocket")) catch |err| log.warn("failed upgrade check:\n{any}\nval: {s}\n", .{ err, hs.upgrade.val });
    std.testing.expect(std.mem.eql(u8, hs.connection.val, "Upgrade")) catch |err| log.warn("failed connection check:\n{any}\nval: {s}\n", .{ err, hs.connection.val });
    std.testing.expect(std.mem.eql(u8, hs.key.val, "dGhlIHNhbXBsZSBub25jZQ==")) catch |err| log.warn("failed key check:\n{any}\nval: {s}\n", .{ err, hs.key.val });
    std.testing.expect(std.mem.eql(u8, hs.origin.?.val, "http://example.com")) catch |err| log.warn("failed origin check:\n{any}\nval: {s}\n", .{ err, hs.origin.?.val });
    std.testing.expect(std.mem.eql(u8, hs.protocol.val, "chat, superchat")) catch |err| log.warn("failed protocol check:\n{any}\nval: {s}\n", .{ err, hs.protocol.val });
    std.testing.expect(std.mem.eql(u8, hs.version.val, "13")) catch |err| log.warn("failed version check:\n{any}\nval: {s}\n", .{ err, hs.version.val });
}
