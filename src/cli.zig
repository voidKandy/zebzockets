const std = @import("std");

pub const CliArgs = struct {
    info: ConnectionInfo,
    /// Contains args iterator in case something using this expects more args
    args: std.process.ArgIterator,
    const Self = @This();

    const usage =
        \\ usage: <binary-name> [<host>:<port>]|--help
        \\ To use default host and port values simply pass ':'
    ;

    /// Calls `std.process.args()`
    pub fn parse() ?Self {
        var args = std.process.args();
        // First arg is always the binary name
        std.debug.assert(args.skip());
        const first_arg = args.next() orelse {
            std.debug.print("{s}", .{usage});
            return null;
        };

        if (std.mem.eql(u8, "--help", first_arg)) {
            std.debug.print("{s}", .{usage});
            return null;
        }
        const info = ConnectionInfo.from(first_arg);

        return Self{ .info = info, .args = args };
    }
};

pub const ConnectionInfo = struct {
    host: []const u8,
    port: u16,

    const default_host = "127.0.0.1";
    const default_port = 6000;
    /// Assumes the `str` passed is formatted as follows:
    /// \<host\>:\<port\>
    /// If either `host` or `port` are missing, replaces them with default values
    fn from(str: []const u8) ConnectionInfo {
        var split = std.mem.split(u8, str, ":");
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
};
