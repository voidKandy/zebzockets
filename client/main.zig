const std = @import("std");
const zz = @import("zebzockets");
const net = std.net;
const print = std.debug.print;
const assert = std.debug.assert;

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
    var handshake = try zz.client_hs.Handshake.init_with_headers(uri, &headers, allocator);
    defer handshake.deinit();
    const body =
        try handshake.body();
    defer body.deinit();
    const size = try writer.write(body.items);
    print("Sending '{s}' to peer, total written: {d} bytes\n", .{ body.items, size });
    const len = try reader.read(&read_buffer);
    const response = read_buffer[0..len];
    const server_handshake = try zz.server_hs.Handshake.try_from_bytes(response);

    if (!server_handshake.is_ok()) {
        std.log.err("server returned non 200 status", .{});
        return error.ServerRespondedNotOk;
    }

    print("Established WS connection with server!\n", .{});
    try run_prompt(allocator, writer);
}

fn run_prompt(allocator: std.mem.Allocator, writer: anytype) !void {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    while (true) {
        try stdout.print("> ", .{});
        var buffer: [1024]u8 = undefined;

        // need to generate this
        const mask_key = [4]u8{ 8, 8, 8, 8 };

        const result = try stdin.readUntilDelimiter(&buffer, '\n');
        const payload = zz.frame.PayloadData.new().application_data(result).mask(mask_key).finish();
        const frame = zz.frame.Frame.build(true, zz.frame.OpCode.text, payload, mask_key);
        std.log.warn("frame: {any}\n", .{frame});
        const bytes = try frame.as_bytes(allocator);
        try writer.writeAll(bytes);
        try stdout.print("Sent Frame\n", .{});
    }
}
