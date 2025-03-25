const std = @import("std");
const zz = @import("zebzockets");
const net = std.net;
const print = std.debug.print;
const assert = std.debug.assert;

/// https://gist.github.com/kassane/a81d1ae2fa2e8c656b91afee8b949426
const std_options = struct {
    const log_level = .debug;

    const log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .debug, .level = .debug },
        .{ .scope = .warn, .level = .warn },
    };
};

const log = std.log.scoped(.warn);

const Server =
    zz.server.Server(zz.frame.TransparentAppData, zz.frame.NullExt);
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
