const std = @import("std");
const zebzockets = @import("zebzockets");
const net = std.net;
const log = std.log;
const print = std.debug.print;
const assert = std.debug.assert;

// The cli has the following possible args:
// > Members marked exclusive change the behaviour of the cli
// --help - Shows help message (exclusive)
// <host>:<port> - each of which are optional
//   <binary> :3000 will use the default host
//   <binary> 192.5.8.65: will use the default port

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
    const info = zebzockets.connection_information(first_arg);
    const loopback = try std.net.Ip4Address.parse(info.host, info.port);

    const localhost = net.Address{ .in = loopback };
    var server = try localhost.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    const addr = server.listen_address;
    print("Listening on {s}:{}, access this port to end the program\n", .{ info.host, addr.getPort() });

    var client = try server.accept();
    defer client.stream.close();

    print("Connection received! {} is sending data.\n", .{client.address});

    const message = try client.stream.reader().readAllAlloc(allocator, 1024);
    var client_handshake = try zebzockets.ClientHandshake.parse(message, allocator);
    defer client_handshake.deinit();
    log.warn("parsed handshake: {any}\n", .{client_handshake});
    const handshake = try ServerHandshake.from_client_handshake(&client_handshake, allocator);
    log.warn("built handshake: {any}\n", .{handshake});
    defer handshake.deinit();
    defer allocator.free(message);

    print("{} says {s}\n", .{ client.address, message });
}

pub const ServerHandshake = struct {
    // there must be some better way of creating configs
    const Config = struct {
        accept: []const u8,
        protocol: []const u8,
        const PROTOCOL = "Sec-WebSocket-Protocol";
        const ACCEPT = "Sec-WebSocket-Accept";
    };
    headers: zebzockets.HeaderMap,
    arena: std.heap.ArenaAllocator,
    const Self = @This();

    fn deinit(self: Self) void {
        self.arena.deinit();
    }

    fn from_client_handshake(client_hs: *zebzockets.ClientHandshake, allocator: std.mem.Allocator) !Self {
        var arena = std.heap.ArenaAllocator.init(allocator);
        // const headers = try zebzockets.ExpectedHeader.all_in_header_map(client_hs.headers, allocator);

        const key = zebzockets.ExpectedHeader.get(zebzockets.ExpectedHeader.Key, &client_hs.headers) orelse return error.NoKey;
        const hashed = try hash_key(arena.allocator(), key.inner_val());
        const base64 = try base64_encode_digest(arena.allocator(), hashed);
        _ = base64;

        return error.BAD;

        // _ = client_hs;
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
