//! Shared library for client and server

const std = @import("std");
const testing = std.testing;
const log = std.log;
const default_host = "127.0.0.1";
const default_port = 6000;

pub const ConnectionInfo = struct {
    host: []const u8,
    port: u16,
};
/// Assumes the `arg` passed is formatted as follows:
/// \<host\>:\<port\>
/// If either `host` or `port` are missing, replaces them with default values
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

const Method = enum {
    options,
    get,
    head,
    post,
    put,
    delete,
    trace,
    connect,

    fn parse(str: []const u8) ?Method {
        inline for (@typeInfo(Method).Enum.fields) |method| {
            var uppercase: [method.name.len]u8 = undefined;
            @memset(&uppercase, 0);
            _ = std.ascii.upperString(&uppercase, method.name);
            if (std.mem.eql(u8, &uppercase, str)) {
                return @enumFromInt(method.value);
            }
        }

        log.err("could not get method from str: {s}\n", .{str});
        return null;
    }
};

pub const ClientHandshake = struct {
    /// Used to populate required headers AFTER initialization
    pub const Config = struct {
        /// Base-64 encoded string that the server concatenates with a Globally Unique Identifier
        /// This concatenated string is then Sha-1 hashed, Base-64 encoded and returned to the client
        key: []const u8,
        host: []const u8,
        /// Used to protect against unauthorized cross-origin use of a WebSocket server by scripts using the WebSocket API in a web browser.
        /// This header field is sent by browser clients; for non-browser clients, this header field may be sent if it makes sense in the context of those clients.
        origin: ?[]const u8,
        version: []const u8,
        subprotocol: []const u8,
    };
    const HeaderMap =
        std.StringArrayHashMap([]const u8);
    headers: HeaderMap,
    endpoint: []const u8,
    arena: std.heap.ArenaAllocator,
    const Self = @This();

    pub fn init(endpoint: []const u8, allocator: std.mem.Allocator) !Self {
        var arena = std.heap.ArenaAllocator.init(allocator);

        var headers = Self.HeaderMap.init(arena.allocator());
        try headers.put("Upgrade", "websocket");
        try headers.put("Connection", "Upgrade");
        // this might need to be configurable

        return Self{
            .headers = headers,
            .endpoint = endpoint,
            .arena = arena,
        };
    }

    pub fn populate_config_headers(self: *Self, config: Self.Config) !void {
        try self.headers.put("Host", config.host);
        if (config.origin) |origin| {
            try self.headers.put("Origin", origin);
        }
        try self.headers.put("Sec-WebSocket-Key", config.key);
        try self.headers.put("Sec-WebSocket-Version", config.version);
        try self.headers.put("Sec-WebSocket-Protocol", config.subprotocol);
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
        return;
    }

    /// converts object into a request body that can be sent
    pub fn body(self: *Self) !std.ArrayList(u8) {
        var buffer = std.ArrayList(u8).init(self.arena.allocator());
        try buffer.appendSlice("GET ");
        try buffer.appendSlice(self.endpoint);
        try buffer.appendSlice(" HTTP/1.1 \r\n");
        var headers_iter =
            self.headers.iterator();
        while (headers_iter.next()) |entry| {
            try buffer.appendSlice(entry.key_ptr.*);
            try buffer.appendSlice(": ");
            try buffer.appendSlice(entry.value_ptr.*);
            try buffer.appendSlice("\r\n");
        }
        return buffer;
    }

    pub fn parse(str: []u8, allocator: std.mem.Allocator) !Self {
        log.info("parsing: {s}\n", .{str});
        var line_split = std.mem.splitSequence(u8, str, "\r\n");
        const leading_line = line_split.first();
        const headers_buffer = line_split.buffer[leading_line.len..];
        var leading_line_whitespace_split = std.mem.splitScalar(u8, leading_line, ' ');

        const method = Method.parse(leading_line_whitespace_split.first()) orelse return error.InvalidLeadingLine;
        if (method != Method.get) {
            log.err("Invalid method, got: {any}\n", .{method});
            return error.InvalidMethod;
        }
        const endpoint = leading_line_whitespace_split.next() orelse {
            log.err("Did not get endpoint\n", .{});
            return error.InvalidLeadingLine;
        };
        const http_version = leading_line_whitespace_split.next() orelse {
            log.err("Did not get http_version\n", .{});
            return error.InvalidLeadingLine;
        };

        log.info("Method: {any}\nendpoint: {s}\nhttp_version: {s}\n", .{ method, endpoint, http_version });
        var self = try Self.init(endpoint, allocator);

        log.info("parsing headers from buffer: {s}\n", .{headers_buffer});
        var headers_split = std.mem.splitSequence(u8, headers_buffer, "\r\n");

        // var current_key: ?std.ArrayList(u8).Slice = null;
        const buffer_size: comptime_int = 64;
        var current_key: [buffer_size]u8 = undefined;
        @memset(&current_key, 0);
        var current_key_len: usize = 0;

        var buf: [buffer_size]u8 = undefined;
        @memset(&buf, 0);
        var cursor: usize = 0;
        // var buf = std.ArrayList(u8).init(allocator);
        // defer buf.deinit();
        while (headers_split.next()) |this_header| {
            if (std.mem.trim(u8, this_header, " ").len == 0) {
                continue;
            }
            for (this_header) |char| {
                switch (char) {
                    ' ' => {
                        // if (buf.items.len != 0) {
                        if (buf.len != 0) {
                            buf[cursor] = char;
                            cursor += 1;
                            std.debug.assert(cursor < buffer_size);
                            // try buf.append(char);
                        }
                    },
                    ':' => {
                        @memcpy(&current_key, &buf);
                        current_key_len = cursor;
                        log.info("setting key to: {s}\n", .{current_key[0..current_key_len]});
                        cursor = 0;
                    },
                    else => {
                        buf[cursor] = char;
                        cursor += 1;
                        std.debug.assert(cursor < buffer_size);
                    },
                }
            }
            if (current_key_len != 0) {
                const trimmed_key =
                    std.mem.trim(u8, current_key[0..current_key_len], " ");
                const trimmed_val =
                    std.mem.trim(u8, buf[0..cursor], " ");
                const key = try self.arena.allocator().alloc(u8, trimmed_key.len);
                const val = try self.arena.allocator().alloc(u8, trimmed_val.len);
                @memcpy(key, trimmed_key);
                @memcpy(val, trimmed_val);
                log.info("inserting val: {s} into key: {s}\n", .{ val, key });
                try self.headers.put(key, val);
                current_key_len = 0;
                cursor = 0;
            } else {
                log.err("did not get a key for header buffer: {s}\n", .{this_header});
            }
        }
        return self;
    }
};

test "client handshake building" {
    const allocator = std.testing.allocator;
    const handshake_cfg = ClientHandshake.Config{
        .key = "dGhlIHNhbXBsZSBub25jZQ==",
        .host = "127.0.0.1",
        .origin = null,
        .version = "13",
        .subprotocol = "chat, superchat",
    };
    var handshake = try ClientHandshake.init("/chat", allocator);
    try handshake.populate_config_headers(handshake_cfg);
    defer handshake.deinit();
    const body = try handshake.body();
    defer body.deinit();
    std.debug.print("BODY: {s}\n", .{body.items});
    std.debug.print("CLIENT HANDSHAKE BUILDING PASSED\n", .{});
}

test "client handshake parsing" {
    const allocator = std.testing.allocator;

    const handshake_cfg = ClientHandshake.Config{
        .key = "dGhlIHNhbXBsZSBub25jZQ==",
        .host = "127.0.0.1",
        .origin = null,
        .version = "13",
        .subprotocol = "chat, superchat",
    };
    var expected_handshake = try ClientHandshake.init("/chat", allocator);
    try expected_handshake.populate_config_headers(handshake_cfg);
    defer expected_handshake.deinit();
    const body = try expected_handshake.body();
    defer body.deinit();

    var handshake = try ClientHandshake.parse(body.items, allocator);
    defer handshake.deinit();

    if (!std.mem.eql(u8, handshake.endpoint, expected_handshake.endpoint)) {
        std.debug.panic("endpoints do not match, expected={s}\ngot={s}\n", .{ expected_handshake.endpoint, handshake.endpoint });
    }
    var got_iter = handshake.headers.iterator();

    while (got_iter.next()) |entry| {
        log.warn("ENTRY:\nKEY: {s}\nVAL: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        const got = expected_handshake.headers.get(entry.key_ptr.*) orelse std.debug.panic("expected handshake does not have entry for key: {s}\n", .{entry.key_ptr.*});
        if (!std.mem.eql(u8, got, entry.value_ptr.*)) {
            std.debug.panic("expected value: {s} for key {s}\ngot={s}\n", .{ entry.value_ptr.*, entry.key_ptr.*, got });
        }
    }

    std.debug.print("HANDSHAKE PARSING PASSED\n", .{});
}

test "parse method" {
    const get = "GET";
    const get_method = Method.parse(get) orelse std.debug.panic("Failed to parse get method", .{});
    try std.testing.expectEqual(Method.get, get_method);
    std.debug.print("METHOD PARSING PASSED\n", .{});
}
