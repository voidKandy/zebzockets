//! Shared library for client and server
const std = @import("std");
pub const cli = @import("cli.zig");
const testing = std.testing;
const log = std.log;

pub const WsUri = struct {
    secure: bool,
    port: []const u8,
    host: []const u8,
    path: []const u8,
    query: ?[]const u8,

    const Self = @This();
    const SECURE_PORT_DEFAULT = "443";
    const INSECURE_PORT_DEFAULT = "80";

    fn eql(self: Self, other: Self) bool {
        if (self.secure != other.secure) return false;
        if (!std.mem.eql(u8, self.port, other.port)) return false;
        if (!std.mem.eql(u8, self.host, other.host)) return false;
        if (!std.mem.eql(u8, self.path, other.path)) return false;
        if (self.query) |uq| {
            const oq = other.query orelse return false;
            return std.mem.eql(u8, uq, oq);
        }
        return true;
    }

    pub fn from_str(str: []const u8) !Self {
        const first_colon_idx = std.mem.indexOfScalar(u8, str, ':') orelse return error.NoColon;
        const protocol_slice =
            str[0..first_colon_idx];
        log.warn("Protocol Slice: {s}\n", .{protocol_slice});
        if (!std.mem.eql(u8, str[first_colon_idx + 1 .. first_colon_idx + 3], "//")) {
            log.err("Should have gotten '//' after first colon\n{s}\n", .{str});
            return error.InvalidUriStr;
        }

        const host_port_path_slice = str[first_colon_idx + 3 ..];
        log.warn("Host Port Path Slice: {s}\n", .{host_port_path_slice});
        const secure = blk: {
            if (std.mem.eql(u8, protocol_slice, "ws")) {
                break :blk false;
            } else if (std.mem.eql(u8, protocol_slice, "wss")) {
                break :blk true;
            } else {
                log.err("encountered unexpected protocol: {s}\n", .{protocol_slice});
                return error.InvalidProtocol;
            }
        };

        var port_present = false;
        var port: ?[]const u8 = null;
        const host_cutoff = blk: {
            if (std.mem.indexOfScalar(u8, host_port_path_slice, ':')) |i| {
                port_present = true;
                break :blk i;
            } else if (std.mem.indexOfScalar(u8, host_port_path_slice, '/')) |i| {
                break :blk i;
            } else return error.InvalidUriStr;
        };
        const host = host_port_path_slice[0..host_cutoff];
        var host_port_slice_cutoff = host_cutoff;
        if (port_present) {
            const port_cutoff = std.mem.indexOfScalar(u8, host_port_path_slice, '/') orelse return error.InvalidUriStr;
            port = host_port_path_slice[host_cutoff + 1 .. port_cutoff];
            host_port_slice_cutoff = port_cutoff;
        } else {
            port = switch (secure) {
                true => SECURE_PORT_DEFAULT,
                false => INSECURE_PORT_DEFAULT,
            };
        }

        var query: ?[]const u8 = null;
        var path_slice = host_port_path_slice[host_port_slice_cutoff..];
        log.warn("Path Slice: {s}\n", .{path_slice});
        if (std.mem.indexOfScalar(u8, path_slice, '?')) |i| {
            query = if (std.mem.indexOfScalar(u8, path_slice, '#')) |e|
                host_port_path_slice[i + host_port_slice_cutoff + 1 .. host_port_slice_cutoff + e]
            else
                host_port_path_slice[i + host_port_slice_cutoff + 1 ..];
            path_slice = host_port_path_slice[host_port_slice_cutoff .. host_port_slice_cutoff + i];
        }
        return Self{
            .path = path_slice,
            .query = query,
            .port = port.?,
            .host = host,
            .secure = secure,
        };
    }
};

pub const Method = enum {
    options,
    get,
    head,
    post,
    put,
    delete,
    trace,
    connect,

    pub fn parse(str: []const u8) ?Method {
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

pub const HeaderMap =
    std.StringArrayHashMap([]const u8);
const Tag = enum { host, origin, key, protocol, accept, extensions, version, upgrade, connection };
/// Any headers that the WS protocol expects can be defined here
/// Connection and Upgrade headers are not included because they can only be of a single value
pub const ExpectedHeader = union(Tag) {
    host: Host,
    /// Used to protect against unauthorized cross-origin use of a WebSocket server by scripts using the WebSocket API in a web browser.
    /// This header field is sent by browser clients; for non-browser clients, this header field may be sent if it makes sense in the context of those clients.
    origin: Origin,
    /// Base-64 encoded string that the server concatenates with a Globally Unique Identifier
    /// This concatenated string is then Sha-1 hashed, Base-64 encoded and returned to the client
    key: Key,
    protocol: Protocol,
    accept: Accept,

    extensions: Extensions,
    /// **Always** "13"
    version: Version,
    /// **Always** contains "websocket"
    upgrade: Upgrade,
    /// **Always** "Upgrade"
    connection: Connection,

    const Self = @This();

    pub const Host = Self.Inner("Host");
    pub const Origin = Self.Inner("Origin");
    pub const Key = Self.Inner("Sec-WebSocket-Key");
    pub const Protocol = Self.Inner("Sec-WebSocket-Protocol");
    pub const Accept = Self.Inner("Sec-WebSocket-Accept");
    pub const Extensions = Self.Inner("Sec-WebSocket-Extensions");

    pub const Version = Self.Inner("Sec-WebSocket-Version");
    pub const Upgrade = Self.Inner("Upgrade");
    pub const Connection = Self.Inner("Connection");

    pub const VERSION =
        Version.new("13");
    pub const UPGRADE =
        Upgrade.new("websocket");
    pub const CONNECTION =
        Connection.new("Upgrade");

    fn Inner(
        comptime KeyStr: []const u8,
    ) type {
        return struct {
            const MyKey = KeyStr;
            const InnerSelf = @This();

            val: []const u8,
            // for runtime access of KeyStr from instance
            fn key(self: InnerSelf) []const u8 {
                _ = self;
                return KeyStr;
            }
            fn new(val: []const u8) InnerSelf {
                return InnerSelf{ .val = val };
            }
        };
    }
    /// Expects a *Single line* string
    pub fn try_from_str(str: []const u8) ?Self {
        const colon_idx = std.mem.indexOfScalar(u8, str, ':').?;
        const header = std.mem.trim(u8, str[0..colon_idx], " ");
        const val = std.mem.trim(u8, str[colon_idx + 1 ..], " ");
        inline for (@typeInfo(Self).Union.fields) |f| {
            if (std.mem.eql(u8, f.type.MyKey, header)) {
                const v = f.type.new(val);
                return @unionInit(Self, f.name, v);
            }
        }
        return null;
    }
    /// Expects `inner` to be an `Self.Inner`, will panic Otherwise
    pub fn from(comptime inner: type, val: []const u8) Self {
        inline for (@typeInfo(Self).Union.fields) |f| {
            if (f.type == inner) {
                const v = inner.new(val);
                return @unionInit(Self, f.name, v);
            }
        }
    }
    /// Expects `field` to be an `Self.Inner`, will panic Otherwise
    pub fn get(comptime field: type, map: *HeaderMap) ?Self {
        const k = field.MyKey;
        const v = map.get(k) orelse return null;
        return Self.from(field, v);
    }

    pub fn put(self: Self, map: *HeaderMap) !void {
        const info = switch (self) {
            .host => |f| .{ .key = f.key(), .val = f.val },
            .origin => |f| .{ .key = f.key(), .val = f.val },
            .key => |f| .{ .key = f.key(), .val = f.val },
            .version => |f| .{ .key = f.key(), .val = f.val },
            .protocol => |f| .{ .key = f.key(), .val = f.val },
            .accept => |f| .{ .key = f.key(), .val = f.val },
            .upgrade => |f| .{ .key = f.key(), .val = f.val },
            .connection => |f| .{ .key = f.key(), .val = f.val },
            .extensions => |f| .{ .key = f.key(), .val = f.val },
        };

        return map.put(info.key, info.val);
    }

    pub fn inner_val(self: Self) []const u8 {
        return switch (self) {
            .host => |f| f.val,
            .origin => |f| f.val,
            .key => |f| f.val,
            .version => |f| f.val,
            .protocol => |f| f.val,
            .accept => |f| f.val,
        };
    }
};

test "parse method" {
    const get = "GET";
    const get_method = Method.parse(get) orelse std.debug.panic("Failed to parse get method", .{});
    try std.testing.expectEqual(Method.get, get_method);
}

test "Expected Header from str" {
    const header = ExpectedHeader.try_from_str("Host: www.example.com") orelse return error.Fail;
    _ = header;
}

test "Websocket URI parsing works" {
    const Case = struct { expected: WsUri, str: []const u8 };
    const cases: []const Case = &.{
        Case{
            .expected = WsUri{
                .secure = true,
                .port = "443",
                .host = "www.somehost.com",
                .path = "/",
                .query = null,
            },
            .str = "wss://www.somehost.com/",
        },
        Case{
            .expected = WsUri{
                .secure = false,
                .port = "4000",
                .host = "www.somehost.com",
                .path = "/this",
                .query = null,
            },
            .str = "ws://www.somehost.com:4000/this",
        },
        Case{
            .expected = WsUri{
                .secure = true,
                .port = "443",
                .host = "www.somehost.com",
                .path = "/this",
                .query = "some=query",
            },
            .str = "wss://www.somehost.com/this?some=query",
        },
        Case{
            .expected = WsUri{
                .secure = true,
                .port = "443",
                .host = "www.somehost.com",
                .path = "/this",
                .query = "some=query&other=query",
            },
            .str = "wss://www.somehost.com/this?some=query&other=query#",
        },
    };

    for (cases) |case| {
        const got = try WsUri.from_str(case.str);

        if (!case.expected.eql(got)) {
            std.debug.print("Did not get expected URI.\n", .{});
            std.debug.print("Expected\n  host={s}\n  port={s}\n  path={s}\n  query={s}\n", .{
                case.expected.host,
                case.expected.port,
                case.expected.path,
                case.expected.query orelse "NoQuery",
            });
            std.debug.print("Got\n  host={s}\n  port={s}\n  path={s}\n  query={s}\n", .{
                got.host,
                got.port,
                got.path,
                got.query orelse "NoQuery",
            });
        }
    }
}
