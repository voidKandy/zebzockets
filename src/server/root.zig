pub const handshake = @import("handshake.zig");
const zz = @import("../root.zig");
const std = @import("std");

pub fn Server(AppData: type, ExtData: type) type {
    return struct {
        pool: std.Thread.Pool,
        listener: std.net.Server,
        allocator: std.mem.Allocator,
        const Self = @This();
        const Frame = zz.frame.Frame(AppData, ExtData);

        pub fn init(listener: std.net.Server, allocator: std.mem.Allocator) !Self {
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

        pub fn deinit(self: *Self) void {
            self.pool.deinit();
            self.listener.deinit();
        }

        pub fn handle(conn: std.net.Server.Connection) void {
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
            std.log.info("Connection received! {} is sending data.\n", .{conn.address});
            var read_buffer: [4096]u8 = undefined;
            var recv_total: usize = 0;

            var writer = conn.stream.writer();
            var reader = conn.stream.reader();

            recv_total = try reader.read(&read_buffer);
            const message = read_buffer[0..recv_total];
            std.log.info("{} says {s}\n", .{ conn.address, message });

            const client_handshake = try zz.client.handshake.Handshake.try_from_bytes(message);
            var server_handshake = try handshake.Handshake.from_client_handshake(client_handshake, allocator);
            defer server_handshake.deinit();

            const body = try server_handshake.body();
            defer body.deinit();
            const size = try writer.write(body.items);
            std.log.info("Sending '{s}' to peer, total written: {d} bytes\n", .{ body.items, size });

            while (true) {
                const frame = try Frame.read(reader, allocator);
                defer frame.deinit();
                const payload = try frame.payload_data();
                // currently we just ping
                const response_frame = try Frame.init(.{
                    .fin = true,
                    .opcode = zz.frame.OpCode.text,
                    .allocator = allocator,
                    .app_data = payload.app_data,
                    .ext_data = payload.ext_data,
                });
                defer response_frame.deinit();

                const bytes = try response_frame.serialize();
                try writer.writeAll(bytes);
            }
        }
    };
}
