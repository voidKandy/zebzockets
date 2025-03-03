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

    const headers: [4]zebzockets.ExpectedHeader =
        .{
        zebzockets.ExpectedHeader.from(zebzockets.ExpectedHeader.Key, "dGhlIHNhbXBsZSBub25jZQ=="),
        zebzockets.ExpectedHeader.from(zebzockets.ExpectedHeader.Host, "127.0.0.1"),
        zebzockets.ExpectedHeader.from(zebzockets.ExpectedHeader.Version, "13"),
        zebzockets.ExpectedHeader.from(zebzockets.ExpectedHeader.Protocol, "chat, superchat"),
    };
    var handshake = try zebzockets.ClientHandshake.init_with_headers("/chat", &headers, allocator);
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
