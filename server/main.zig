const std = @import("std");
const zz = @import("zebzockets");
const net = std.net;
const log = std.log;
const print = std.debug.print;
const assert = std.debug.assert;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = zz.cli.CliArgs.parse() orelse return;

    const addr = try net.Address.resolveIp(args.info.host, args.info.port);
    var listener = try addr.listen(.{ .reuse_address = true });
    print("Listening on {s}:{}, access this port to end the program\n", .{ args.info.host, listener.listen_address.getPort() });
    var server = try Server.init(listener, allocator);
    defer server.deinit();

    var wg = std.Thread.WaitGroup{};
    while (true) {
        if (!wg.isDone()) {
            server.pool.waitAndWork(&wg);
        }
        const conn = try server.listener.accept();
        server.pool.spawnWg(&wg, Server.handle, .{conn});
    }
}

pub const Server = struct {
    pool: std.Thread.Pool,
    listener: std.net.Server,
    allocator: std.mem.Allocator,
    const Self = @This();

    fn init(listener: std.net.Server, allocator: std.mem.Allocator) !Self {
        var pool: std.Thread.Pool = undefined;
        try pool.init(.{
            .allocator = allocator,
            .n_jobs = 4,
        });
        return Self{
            .listener = listener,
            .allocator = allocator,
            .pool = pool,
        };
    }

    fn deinit(self: *Self) void {
        self.pool.deinit();
        self.listener.deinit();
    }

    fn handle(conn: std.net.Server.Connection) void {
        Self._handle(conn) catch |err| switch (err) {
            // should have graceful close
            // error.Closed => {},
            else => std.debug.print("[{any}] client handle error: {}\n", .{ conn.address, err }),
        };
    }

    fn _handle(conn: std.net.Server.Connection) !void {
        defer conn.stream.close();
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();
        print("Connection received! {} is sending data.\n", .{conn.address});
        var read_buffer: [4096]u8 = undefined;
        var recv_total: usize = 0;

        var writer = conn.stream.writer();
        var reader = conn.stream.reader();

        recv_total = try reader.read(&read_buffer);
        const message = read_buffer[0..recv_total];
        print("{} says {s}\n", .{ conn.address, message });

        const client_handshake = try zz.client_hs.Handshake.try_from_bytes(message);
        var server_handshake = try zz.server_hs.Handshake.from_client_handshake(client_handshake, allocator);
        defer server_handshake.deinit();

        const body = try server_handshake.body();
        defer body.deinit();
        const size = try writer.write(body.items);
        print("Sending '{s}' to peer, total written: {d} bytes\n", .{ body.items, size });

        while (true) {
            const frame = try zz.frame.Frame.read(reader, allocator);
            _ = frame;
        }
    }
};
