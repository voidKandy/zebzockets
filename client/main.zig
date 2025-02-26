const std = @import("std");
const net = std.net;
const print = std.debug.print;
const assert = std.debug.assert;

const default_host = "127.0.0.1";
const default_port = 6000;
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
    var split = std.mem.split(u8, first_arg, ":");
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

    const peer = try net.Address.parseIp4(host, port);
    // Connect to peer
    const stream = try net.tcpConnectToAddress(peer);
    defer stream.close();
    print("Connecting to {}\n", .{peer});

    // Sending data to peer
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
