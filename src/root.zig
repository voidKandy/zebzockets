//! Shared library for client and server

const std = @import("std");
const testing = std.testing;

const default_host = "127.0.0.1";
const default_port = 6000;

pub const ConnectionInfo = struct {
    host: []const u8,
    port: u16,
};
pub fn connection_information(arg: []const u8) ConnectionInfo {
    var split = std.mem.split(u8, arg, ":");
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

    return .{ .host = host, .port = port };
    // return try std.net.Address.parseIp4(host, port);
}
