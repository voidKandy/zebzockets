const root = @import("root.zig");
const std = @import("std");
const log = std.log;

pub const Handshake = struct {
    headers: root.HeaderMap,
    arena: std.heap.ArenaAllocator,
    const Self = @This();

    pub fn deinit(self: Self) void {
        self.arena.deinit();
    }

    pub const Deserialized = struct {
        http_version: []const u8,
        status_code: u16,
        status_message: []const u8,
        version: root.ExpectedHeader.Version,
        upgrade: root.ExpectedHeader.Upgrade,
        connection: root.ExpectedHeader.Connection,
        accept: root.ExpectedHeader.Accept,
        protocol: ?root.ExpectedHeader.Protocol,
        extensions: ?root.ExpectedHeader.Extensions,

        const Builder = struct {
            http_version: []const u8,
            status_code: u16,
            status_message: []const u8,
            version: ?root.ExpectedHeader.Version = null,
            upgrade: ?root.ExpectedHeader.Upgrade = null,
            connection: ?root.ExpectedHeader.Connection = null,
            accept: ?root.ExpectedHeader.Accept = null,
            protocol: ?root.ExpectedHeader.Protocol = null,
            extensions: ?root.ExpectedHeader.Extensions = null,
        };

        pub fn new(http_version: []const u8, code: u16, message: []const u8) Builder {
            return Builder{
                .http_version = http_version,
                .status_code = code,
                .status_message = message,
            };
        }

        pub fn build(builder: Builder) !Self.Deserialized {
            return Self.Deserialized{
                .http_version = builder.http_version,
                .status_code = builder.status_code,
                .status_message = builder.status_message,
                .version = builder.version orelse return error.MissingFieldVersion,
                .upgrade = builder.upgrade orelse return error.MissingFieldUpgrade,
                .connection = builder.connection orelse return error.MissingFieldConnection,
                .accept = builder.accept orelse return error.MissingFieldAccept,
                .protocol = builder.protocol,
                .extensions = builder.extensions,
            };
        }
    };

    pub fn from_client_handshake(hs: root.client_hs.Handshake.Deserialized, allocator: std.mem.Allocator) !Self {
        var arena = std.heap.ArenaAllocator.init(allocator);
        var headers = root.HeaderMap.init(arena.allocator());

        const hashed = try hash_key(arena.allocator(), hs.key.val);
        const base64 = try base64_encode_digest(arena.allocator(), hashed);
        const accept = root.ExpectedHeader.from(root.ExpectedHeader.Accept, base64);
        const version = root.ExpectedHeader.from(root.ExpectedHeader.Version, hs.version.val);
        const upgrade = root.ExpectedHeader.from(root.ExpectedHeader.Upgrade, hs.upgrade.val);
        const connection = root.ExpectedHeader.from(root.ExpectedHeader.Connection, hs.connection.val);

        // do something with origin to validate?
        var origin: ?root.ExpectedHeader = null;
        if (hs.origin) |o| {
            origin = root.ExpectedHeader.from(root.ExpectedHeader.Origin, o.val);
        }
        // validate resource exists
        _ = hs.resource;

        // choose subprotocol
        var protocols = std.mem.split(u8, hs.protocol.val, ",");
        const protocol =
            root.ExpectedHeader.from(root.ExpectedHeader.Protocol, protocols.first());

        if (hs.extensions) |e| {
            _ = e;
            // if you want to support extensions
            // const extension=  zebzockets.ExpectedHeader.from(zebzockets.ExpectedHeader.Extensions, "");
        }

        try accept.put(&headers);
        try upgrade.put(&headers);
        try version.put(&headers);
        try connection.put(&headers);
        try protocol.put(&headers);

        return Self{
            .headers = headers,
            .arena = arena,
        };
    }

    pub fn body(self: *Self) std.mem.Allocator.Error!std.ArrayList(u8) {
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

    pub fn try_from_bytes(bytes: []u8) !Self.Deserialized {
        var lines = std.mem.splitScalar(u8, bytes, '\n');

        const leading_line = lines.first();
        var leading_line_whitespace_split = std.mem.splitScalar(u8, leading_line, ' ');

        const http_version = leading_line_whitespace_split.first();
        const status: []const u8 = leading_line_whitespace_split.next() orelse {
            log.err("Did not get status\n", .{});
            return error.InvalidLeadingLine;
        };
        const status_code = std.fmt.parseInt(u16, status, 10) catch |e| {
            log.err("failed to parse status str to integer\nstr: {s}\nerr: {}\n", .{ status, e });
            return error.InvalidStatusCode;
        };

        const status_message = leading_line_whitespace_split.rest();

        var builder = Self.Deserialized.new(http_version, status_code, status_message);
        while (lines.next()) |line| {
            // log.warn("trying header from line: {s}\n", .{line});
            if (root.ExpectedHeader.try_from_str(line)) |header| {
                switch (header) {
                    .version => |i| builder.version = i,
                    .upgrade => |i| builder.upgrade = i,
                    .connection => |i| builder.connection = i,
                    .accept => |i| builder.accept = i,
                    .protocol => |i| builder.protocol = i,
                    .extensions => |i| builder.extensions = i,
                    else => |i| log.warn("ignoring header: {any}\n", .{i}),
                }
            }
        }
        return Self.Deserialized.build(builder);
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
    std.debug.print("PASSED PROCESS KEY\n", .{});
}
