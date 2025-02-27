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

    const config = websockets.ClientHandshake.Config{
        .key = "dGhlIHNhbXBsZSBub25jZQ==",
        .host = "127.0.0.1",
        .origin = null,
        .subprotocol = "chat, superchat",
        .version = "13",
    };
    var handshake = try websockets.ClientHandshake.init("/chat", allocator);
    try handshake.populate_config_headers(config);
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
