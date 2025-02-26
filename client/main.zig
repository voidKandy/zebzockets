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
    _ =
        \\ GET /chat HTTP/1.1
        \\ Host: server.example.com
        \\ Upgrade: websocket
        \\ Connection: Upgrade
        \\ Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
        \\ Origin: http://example.com
        \\ Sec-WebSocket-Protocol: chat, superchat
        \\ Sec-WebSocket-Version: 13
    ;
    const data = "hello zig";
    var writer = stream.writer();
    const size = try writer.write(data);
    print("Sending '{s}' to peer, total written: {d} bytes\n", .{ data, size });
    // Or just using `writer.writeAll`
    // try writer.writeAll("hello zig");
}

test "health" {
    try std.testing.expect(true);
}
