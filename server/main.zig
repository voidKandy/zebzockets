//! Start a TCP server at an unused port.
//!
//! Test with
//! echo "hello zig" | nc localhost <port>

const std = @import("std");
const websockets = @import("websockets");
const net = std.net;
const print = std.debug.print;
const assert = std.debug.assert;

// The cli has the following possible args:
// > Members marked exclusive change the behaviour of the cli
// --help - Shows help message (exclusive)
// <host>:<port> - each of which are optional
//   <binary> :3000 will use the default host
//   <binary> 192.5.8.65: will use the default port

const default_host = "127.0.0.1";
const default_port = 6000;
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
    defer allocator.free(message);

    print("{} says {s}\n", .{ client.address, message });
}

test "health" {
    try std.testing.expect(true);
}
