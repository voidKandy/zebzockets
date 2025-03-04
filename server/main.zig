const std = @import("std");
const zebzockets = @import("zebzockets");
const net = std.net;
const log = std.log;
const print = std.debug.print;
const assert = std.debug.assert;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = zebzockets.cli.CliArgs.parse() orelse return;

    const loopback = try std.net.Ip4Address.parse(args.info.host, args.info.port);

    const localhost = net.Address{ .in = loopback };
    var server = try localhost.listen(.{
        .reuse_address = true,
    });
    var read_buffer: [1024]u8 = undefined;
    defer server.deinit();

    const addr = server.listen_address;
    print("Listening on {s}:{}, access this port to end the program\n", .{ args.info.host, addr.getPort() });

    var client = try server.accept();
    defer client.stream.close();
    var writer = client.stream.writer();
    var reader = client.stream.reader();

    print("Connection received! {} is sending data.\n", .{client.address});

    const len = try reader.read(&read_buffer);
    const message = read_buffer[0..len];
    print("{} says {s}\n", .{ client.address, message });

    const client_handshake = try ClientHandshake.try_from_message(message);
    var server_handshake = try Handshake.from_client_handshake(client_handshake, allocator);
    log.warn("got server handshake\n", .{});
    defer server_handshake.deinit();

    const body = try server_handshake.body();
    defer body.deinit();
    const size = try writer.write(body.items);
    print("Sending '{s}' to peer, total written: {d} bytes\n", .{ body.items, size });
}

pub const Handshake = struct {
    headers: zebzockets.HeaderMap,
    arena: std.heap.ArenaAllocator,
    const Self = @This();

    fn deinit(self: Self) void {
        self.arena.deinit();
    }

    fn from_client_handshake(hs: ClientHandshake, allocator: std.mem.Allocator) !Self {
        var arena = std.heap.ArenaAllocator.init(allocator);
        var headers = zebzockets.HeaderMap.init(arena.allocator());

        const hashed = try hash_key(arena.allocator(), hs.key.val);
        const base64 = try base64_encode_digest(arena.allocator(), hashed);
        const accept = zebzockets.ExpectedHeader.from(zebzockets.ExpectedHeader.Accept, base64);
        const version = zebzockets.ExpectedHeader.from(zebzockets.ExpectedHeader.Version, hs.version.val);
        const connection = zebzockets.ExpectedHeader.from(zebzockets.ExpectedHeader.Connection, hs.connection.val);

        // do something with origin to validate?
        var origin: ?zebzockets.ExpectedHeader = null;
        if (hs.origin) |o| {
            origin = zebzockets.ExpectedHeader.from(zebzockets.ExpectedHeader.Origin, o.val);
        }
        // validate resource exists
        _ = hs.resource;

        // choose subprotocol
        var protocols = std.mem.split(u8, hs.protocol.val, ",");
        const protocol =
            zebzockets.ExpectedHeader.from(zebzockets.ExpectedHeader.Protocol, protocols.first());

        if (hs.extensions) |e| {
            _ = e;
            // if you want to support extensions
            // const extension=  zebzockets.ExpectedHeader.from(zebzockets.ExpectedHeader.Extensions, "");
        }

        try accept.put(&headers);
        try version.put(&headers);
        try connection.put(&headers);
        try protocol.put(&headers);

        return Self{
            .headers = headers,
            .arena = arena,
        };
    }

    fn body(self: *Self) std.mem.Allocator.Error!std.ArrayList(u8) {
        var buffer = std.ArrayList(u8).init(self.arena.allocator());
        // this http version should reflect the version in the client handshake
        try buffer.appendSlice("HTTP/1.1 101 Switching Protocols\r\n");

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

const ClientHandshake = struct {
    resource: []const u8,
    host: zebzockets.ExpectedHeader.Host,
    key: zebzockets.ExpectedHeader.Key,
    version: zebzockets.ExpectedHeader.Version,
    connection: zebzockets.ExpectedHeader.Connection,
    upgrade: zebzockets.ExpectedHeader.Upgrade,
    protocol: zebzockets.ExpectedHeader.Protocol,
    origin: ?zebzockets.ExpectedHeader.Origin,
    extensions: ?zebzockets.ExpectedHeader.Extensions,
    const Self = @This();

    const Builder = struct { resource: ?[]const u8 = null, host: ?zebzockets.ExpectedHeader.Host = null, connection: ?zebzockets.ExpectedHeader.Connection = null, key: ?zebzockets.ExpectedHeader.Key = null, version: ?zebzockets.ExpectedHeader.Version = null, upgrade: ?zebzockets.ExpectedHeader.Upgrade = null, protocol: ?zebzockets.ExpectedHeader.Protocol = null, origin: ?zebzockets.ExpectedHeader.Origin = null, extensions: ?zebzockets.ExpectedHeader.Extensions = null };

    fn new() Builder {
        return Builder{};
    }

    fn build(builder: Builder) !Self {
        return Self{
            .resource = builder.resource orelse return error.MissingField,
            .host = builder.host orelse return error.MissingField,
            .key = builder.key orelse return error.MissingField,
            .version = builder.version orelse return error.MissingField,
            .upgrade = builder.upgrade orelse return error.MissingField,
            .protocol = builder.protocol orelse return error.MissingField,
            .connection = builder.connection orelse return error.MissingField,
            .origin = builder.origin,
            .extensions = builder.extensions,
        };
    }
    fn try_from_message(msg: []u8) !ClientHandshake {
        var lines = std.mem.splitScalar(u8, msg, '\n');

        const leading_line = lines.first();
        var leading_line_whitespace_split = std.mem.splitScalar(u8, leading_line, ' ');

        const method = zebzockets.Method.parse(leading_line_whitespace_split.first()) orelse return error.InvalidLeadingLine;
        if (method != zebzockets.Method.get) {
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

        var builder = ClientHandshake.new();
        builder.resource = path;
        while (lines.next()) |line| {
            // log.warn("trying header from line: {s}\n", .{line});
            if (zebzockets.ExpectedHeader.try_from_str(line)) |header| {
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
        return ClientHandshake.build(builder);
    }
};

const Sha1 = std.crypto.hash.Sha1;
/// Concatenates a UUID to the given key and returns a Hash of the combination
fn hash_key(allocator: std.mem.Allocator, key: []const u8) std.mem.Allocator.Error![Sha1.digest_length]u8 {
    // eventually, generate this
    // https://codeberg.org/joshua-software-dev/uuid-zig
    const uuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    const size = uuid.len + key.len;
    var buffer = try allocator.alloc(u8, size);
    defer allocator.free(buffer);
    for (key, 0..) |ch, i| {
        buffer[i] = ch;
    }
    for (uuid, 0..) |ch, i| {
        buffer[i + key.len] = ch;
    }
    var digest: [Sha1.digest_length]u8 = undefined;
    Sha1.hash(buffer, &digest, .{});
    return digest;
}

const Encoder = std.base64.standard.Encoder;
const Decoder = std.base64.standard.Decoder;
/// Base 64 encodes hashed digest
/// Returned []u8 must be cleaned up by the called
fn base64_encode_digest(allocator: std.mem.Allocator, src: [Sha1.digest_length]u8) std.mem.Allocator.Error![]u8 {
    const encoded_length = Encoder.calcSize(src.len);
    const encoded_buffer = try allocator.alloc(u8, encoded_length);
    _ = Encoder.encode(encoded_buffer, &src);
    return encoded_buffer;
    // const decoded_length = try Decoder.calcSizeForSlice(encoded_buffer);
    // const decoded_buffer = try allocator.alloc(u8, decoded_length);
    // defer allocator.free(decoded_buffer);

    // try Decoder.decode(decoded_buffer, encoded_buffer);
    // try std.testing.expectEqualStrings(src, decoded_buffer);
}

test "process key" {
    const allocator = std.testing.allocator;
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const hashed = try hash_key(allocator, key);
    const base64 = try base64_encode_digest(allocator, hashed);
    defer allocator.free(base64);
    log.warn("Hashed Value: {s}\nEncoded: {s}\n", .{ hashed, base64 });
    print("PASSED PROCESS KEY\n", .{});
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
    const hs = try ClientHandshake.try_from_message(msg);
    std.testing.expect(std.mem.eql(u8, hs.host.val, "server.example.com")) catch |err| log.warn("failed host check:\n{any}\nval: {s}\n", .{ err, hs.host.val });
    std.testing.expect(std.mem.eql(u8, hs.upgrade.val, "websocket")) catch |err| log.warn("failed upgrade check:\n{any}\nval: {s}\n", .{ err, hs.upgrade.val });
    std.testing.expect(std.mem.eql(u8, hs.connection.val, "Upgrade")) catch |err| log.warn("failed connection check:\n{any}\nval: {s}\n", .{ err, hs.connection.val });
    std.testing.expect(std.mem.eql(u8, hs.key.val, "dGhlIHNhbXBsZSBub25jZQ==")) catch |err| log.warn("failed key check:\n{any}\nval: {s}\n", .{ err, hs.key.val });
    std.testing.expect(std.mem.eql(u8, hs.origin.?.val, "http://example.com")) catch |err| log.warn("failed origin check:\n{any}\nval: {s}\n", .{ err, hs.origin.?.val });
    std.testing.expect(std.mem.eql(u8, hs.protocol.val, "chat, superchat")) catch |err| log.warn("failed protocol check:\n{any}\nval: {s}\n", .{ err, hs.protocol.val });
    std.testing.expect(std.mem.eql(u8, hs.version.val, "13")) catch |err| log.warn("failed version check:\n{any}\nval: {s}\n", .{ err, hs.version.val });

    _ = try Handshake.from_client_handshake(hs, allocator);
}
