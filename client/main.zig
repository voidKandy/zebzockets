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
const Frame =
    zz.frame.Frame(zz.frame.TransparentAppData, zz.frame.NullExt);
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = zz.cli.CliArgs.parse() orelse return;
    const peer = try std.net.Address.parseIp4(args.info.host, args.info.port);
    var read_buffer: [1024]u8 = undefined;

    const stream = try net.tcpConnectToAddress(peer);
    defer stream.close();
    var writer = stream.writer();
    var reader = stream.reader();
    print("Connecting to {}\n", .{peer});

    const headers = [_]zz.ExpectedHeader{
        zz.ExpectedHeader.from(zz.ExpectedHeader.Key, "dGhlIHNhbXBsZSBub25jZQ=="),
        zz.ExpectedHeader.from(zz.ExpectedHeader.Protocol, "chat, superchat"),
    };
    // shoudl be a cli arg
    const uri = try zz.WsUri.from_str("ws://127.0.0.1/chat");
    var handshake = try zz.client.handshake.Handshake.init_with_headers(uri, &headers, allocator);
    defer handshake.deinit();
    const body =
        try handshake.body();
    defer body.deinit();
    const size = try writer.write(body.items);
    print("Sending '{s}' to peer, total written: {d} bytes\n", .{ body.items, size });
    const len = try reader.read(&read_buffer);
    const response = read_buffer[0..len];
    const server_handshake = try zz.server.handshake.Handshake.try_from_bytes(response);

    if (!server_handshake.is_ok()) {
        log.err("server returned non 200 status", .{});
        return error.ServerRespondedNotOk;
    }

    print("Established WS connection with server!\n", .{});

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator });
    var wg = std.Thread.WaitGroup{};
    pool.spawnWg(&wg, run_prompt, .{ pool.allocator, writer });
    pool.spawnWg(&wg, handle_messages_from_server, .{ pool.allocator, reader });
    pool.waitAndWork(&wg);
}

fn handle_messages_from_server(allocator: std.mem.Allocator, reader: anytype) void {
    _handle_messages_from_server(allocator, reader) catch |e| {
        log.err("Error in handle messages from server: {}\n", .{e});
    };
}
fn run_prompt(allocator: std.mem.Allocator, writer: anytype) void {
    _run_prompt(allocator, writer) catch |e| {
        log.err("Error in run prompt: {}\n", .{e});
    };
}

fn _handle_messages_from_server(allocator: std.mem.Allocator, reader: anytype) !void {
    const stdout = std.io.getStdOut().writer();
    while (true) {
        const frame = try Frame.read(reader, allocator);
        defer frame.deinit();

        log.debug("received frame: {any}\n", .{frame});
        try stdout.print("received from server!\n{s}\n", .{frame._payload_data});
    }
}

fn _run_prompt(allocator: std.mem.Allocator, writer: anytype) !void {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    const rand = std.crypto.random;

    while (true) {
        try stdout.print("> ", .{});
        var buffer: [1024]u8 = undefined;

        // need to generate this
        var mask_key = [_]u8{ 0, 0, 0, 0 };
        for (0..4) |i| {
            mask_key[i] = rand.int(u8);
        }

        const result = try stdin.readUntilDelimiter(&buffer, '\n');
        const frame = try Frame.init(.{
            .fin = true,
            .opcode = zz.frame.OpCode.text,
            .app_data = zz.frame.TransparentAppData.from(result),
            .masking_key = mask_key,
            .allocator = allocator,
        });
        defer frame.deinit();
        log.warn("frame: {any}\n", .{frame});
        const bytes = try frame.serialize();
        try writer.writeAll(bytes);
        try stdout.print("Sent Frame\n", .{});
    }
}
