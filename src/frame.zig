const std = @import("std");
const Allocator = std.mem.Allocator;

pub const NullExtStruct = struct {};
/// A good default for when no extension data is expected
pub const NullExt = ExtensionData(NullExtStruct, Allocator.Error, struct {
    fn create(in: NullExtStruct, ctx: ExtDataCtx(NullExtStruct).Create) Allocator.Error!?[]u8 {
        _ = ctx;
        _ = in;
        return null;
    }
}.create, struct {
    fn read(bytes: []u8, ctx: ExtDataCtx(NullExtStruct).Read) Allocator.Error!ExtDataCtx(NullExtStruct).ReadResult {
        _ = ctx;
        _ = bytes;
        return .{ .inner = .{}, .amt = 0 };
    }
}.read, null);

/// Clones the internal `[]u8` in the case of both serialize and derializing
pub const TransparentAppData = ApplicationData([]u8, Allocator.Error, struct {
    fn serialize(ctx: []u8, a: Allocator) Allocator.Error![]u8 {
        return try a.dupe(u8, ctx);
    }
}.serialize, struct {
    fn deserialize(bytes: []u8, a: Allocator) Allocator.Error![]u8 {
        return try a.dupe(u8, bytes);
    }
}.deserialize, struct {
    fn cleanup(d: []u8, a: Allocator) void {
        a.free(d);
    }
}.cleanup);

/// Good default for when the frame is sending Json data
pub fn JsonAppData(
    Data: type,
    parse_options: std.json.ParseOptions,
    stringify_options: std.json.StringifyOptions,
) type {
    const Error = error{ Allocator, Json };
    const ParsedData = std.json.Parsed(Data);

    return ApplicationData(ParsedData, Error, struct {
        fn ser(data: ParsedData, a: Allocator) Error![]u8 {
            const arr = std.json.stringifyAlloc(a, data.value, stringify_options) catch {
                return error.Allocator;
            };
            return arr;
        }
    }.ser, struct {
        fn deser(bytes: []u8, a: Allocator) Error!ParsedData {
            const parsed = std.json.parseFromSlice(Data, a, bytes, parse_options) catch |e| {
                std.log.err("failed to parse from slice: {?}\n", .{e});
                return error.Json;
            };
            return parsed;
        }
    }.deser, struct {
        fn deinit(d: ParsedData, a: Allocator) void {
            _ = a;
            d.deinit();
        }
    }.deinit);
}

///   Defines the interpretation of the "Payload data".  If an unknown
///   opcode is received, the receiving endpoint MUST _Fail the
///   WebSocket Connection_.  The following values are defined.
///   *  %x0 denotes a continuation frame
///   *  %x1 denotes a text frame
///   *  %x2 denotes a binary frame
///   *  %x3-7 are reserved for further non-control frames
///   *  %x8 denotes a connection close
///   *  %x9 denotes a ping
///   *  %xA denotes a pong
///   *  %xB-F are reserved for further control frames
pub const OpCode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    /// generally reserved for extensions
    undefined_non_control,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    /// generally reserved for extensions
    undefined_control,

    fn from(byte: u4) OpCode {
        switch (byte) {
            @intFromEnum(OpCode.continuation) => OpCode.continuation,
            @intFromEnum(OpCode.text) => OpCode.text,
            @intFromEnum(OpCode.binary) => OpCode.binary,
            0x3...0x7 => OpCode.undefined_non_control,
            @intFromEnum(OpCode.close) => OpCode.close,
            @intFromEnum(OpCode.ping) => OpCode.ping,
            @intFromEnum(OpCode.pong) => OpCode.pong,
            0xB...0xF => OpCode.undefined_control,
        }
    }
};

const ExtendedLenTag = enum {
    sixteen,
    sixtyfour,
};
/// When payload len exceeds 125, we need to use an additional section of the frame to store the length
const ExtendedPayloadLength = union(ExtendedLenTag) {
    /// In this case `payload_len` MUST == 126
    sixteen: u16,
    /// In this case `payload_len` MUST == 127
    sixtyfour: u64,
};

pub const MaskingKey = [4]u8;
/// Masks data in-place, completely reversable by calling the same function again
/// Octet `i` of the `transformed-octet-i` is the XOR of
/// octet `i` of the original data `original-octet-i` with octet at
/// index `i` modulo 4 of the masking key `masking-key-octet-j`:
/// `j` = `i` MOD 4
/// `transformed-octet-i` = `original-octet-i` XOR `masking-key-octet-j`
pub fn mask_data(key: MaskingKey, data: *[]u8) void {
    for (0..data.len) |i| {
        data.*[i] ^= key[i % 4];
    }
}

pub fn ApplicationData(
    comptime Data: type,
    comptime Error: type,
    comptime SerializeFn: *const fn (ctx: Data, a: Allocator) Error![]u8,
    comptime DeserializeFn: *const fn (bytes: []u8, a: Allocator) Error!Data,
    comptime CleanupFn: ?*const fn (d: Data, a: Allocator) void,
) type {
    return struct {
        inner: Data,
        const Self = @This();

        pub inline fn deinit(self: Self, a: Allocator) void {
            if (CleanupFn) |f| {
                f(self.inner, a);
            }
        }

        pub inline fn serialize(self: Self, allocator: Allocator) Error![]u8 {
            return SerializeFn(self.inner, allocator);
        }

        /// function for reading `Context` from the tail of the `payload_data` **AFTER** extension data has been removed
        pub inline fn deserialize(bytes: []u8, allocator: Allocator) Error!Self {
            const ctx = try DeserializeFn(bytes, allocator);
            return Self.from(ctx);
        }

        pub fn from(ctx: Data) Self {
            return Self{ .inner = ctx };
        }
    };
}

pub fn ExtDataCtx(Context: type) type {
    return struct {
        const Self = @This();
        /// Context that is needed for the creation of ExtensionData
        pub const Create = struct {
            rsv1: *u1,
            rsv2: *u1,
            rsv3: *u1,
            opcode: *OpCode,
            app_data: *[]u8,
            allocator: *Allocator,
        };
        /// Context that is needed for the reading ExtensionData from a payload
        pub const Read = struct {
            rsv1: *const u1,
            rsv2: *const u1,
            rsv3: *const u1,
            opcode: *const OpCode,
            payload_len: *const u7,
            extended_payload_len: *const ?ExtendedPayloadLength,
        };

        pub const ReadResult = struct {
            inner: Context,
            amt: usize,
        };
        fn CreateFn(Error: type) type {
            return *const fn (data: Context, create_ctx: Self.Create) Error!?[]u8;
        }
        fn ReadFn(Error: type) type {
            return *const fn (bytes: []u8, read_ctx: Self.Read) Error!Self.ReadResult;
        }
    };
}
/// More likely to change once I'm more familiar with the needs of extensions
pub fn ExtensionData(
    comptime Data: type,
    comptime Error: type,
    comptime CreateFn: ExtDataCtx(Data).CreateFn(Error),
    comptime ReadFn: ExtDataCtx(Data).ReadFn(Error),
    comptime CleanupFn: ?*const fn (d: Data, a: Allocator) void,
) type {
    return struct {
        inner: Data,
        const Self = @This();
        const Context =
            ExtDataCtx(Data);

        pub inline fn deinit(self: Self, a: Allocator) void {
            if (CleanupFn) |f| {
                f(self.inner, a);
            }
        }

        pub inline fn create(self: Self, create_ctx: Context.Create) Error!?[]u8 {
            return CreateFn(self.inner, create_ctx);
        }

        pub inline fn read(bytes: []u8, read_ctx: Context.Read) Error!Context.ReadResult {
            return ReadFn(bytes, read_ctx);
        }

        pub fn from(inner: Data) Self {
            return Self{ .inner = inner };
        }
    };
}

///   https://www.rfc-editor.org/rfc/rfc6455.html#section-5.2
///   It is important to note that the representation of this
///   data is binary, not ASCII characters.  As such, a field with a length
///   of 1 bit that takes values %x0 / %x1 is represented as a single bit
///   whose value is 0 or 1, not a full byte (octet) that stands for the
///   characters "0" or "1" in the ASCII encoding.
pub fn Frame(
    /// **MUST** be a type returned by the `ApplicationData` function
    AppData: anytype,
    /// **MUST** be a type returned by the `ExtensionData` function
    ExtData: anytype,
) type {
    return struct {
        const Self = @This();
        allocator: Allocator,
        fin: u1,
        ///   MUST be 0 unless an extension is negotiated that defines meanings
        ///   for non-zero values.  If a nonzero value is received and none of
        ///   the negotiated extensions defines the meaning of such a nonzero
        ///   value, the receiving endpoint MUST _Fail the WebSocket Connection_.
        rsv1: u1 = 0,
        rsv2: u1 = 0,
        rsv3: u1 = 0,
        /// Defines the interpretation of the "Payload data".
        opcode: OpCode,
        ///   Defines whether the "Payload data" is masked.  If set to 1, a
        ///   masking key is present in masking-key, and this is used to unmask
        ///   the "Payload data" as per Section 5.3.  All frames sent from
        ///   client to server have this bit set to 1.
        mask: u1,
        ///   The length of `payload_data` in bytes if 0-125, 7 bits is enough
        payload_length: u7,
        /// For handling `payload_len` > 125
        extended_payload_length: ?ExtendedPayloadLength,
        ///   All frames sent from the client to the server are masked by a
        ///   32-bit value that is contained within the frame.  This field is
        ///   present if the mask bit is set to 1 and is absent if the mask bit is set to 0.
        masking_key: ?MaskingKey,
        ///   defined as "Extension data" concatenated with "Application data".
        _payload_data: []u8,
        // application_data: []u8,
        // extension_data: ?[]u8,

        /// Size of all fields up until payload length + mask byte in bits
        /// fin (**u1**)
        /// rsv1 (**u1**)
        /// rsv2 (**u1**)
        /// rsv3 (**u1**)
        /// opcode (**u4**)
        pub const INITIAL_READ_SIZE: usize = 8;

        pub fn deinit(self: Self) void {
            self.allocator.free(self._payload_data);
        }

        const PayloadData = struct {
            _source: []u8,
            app_data: AppData,
            ext_data: ?ExtData,

            pub fn deinit(self: PayloadData, allocator: Allocator) void {
                allocator.free(self._source);
                self.app_data.deinit(allocator);
                if (self.ext_data) |ext| {
                    ext.deinit(allocator);
                }
            }
        };

        /// Copies frame's `_payload_data` and returns serialized Extension and Application data
        pub fn payload_data(self: Self) !PayloadData {
            var copy = try self.allocator.dupe(u8, self._payload_data);
            const read_ctx = self.as_read_context();
            const ext_read_result = try ExtData.read(copy, read_ctx);

            const read_amt = ext_read_result.amt;
            var ext_data: ?ExtData =
                null;
            if (read_amt > 0) {
                ext_data = ExtData.from(ext_read_result.inner);
            }

            const app_data = try AppData.deserialize(copy[read_amt..], self.allocator);
            return PayloadData{
                ._source = copy,
                .app_data = app_data,
                .ext_data = ext_data,
            };
        }

        fn as_read_context(self: *const Self) ExtData.Context.Read {
            return ExtData.Context.Read{
                .rsv1 = &self.rsv1,
                .rsv2 = &self.rsv2,
                .rsv3 = &self.rsv3,
                .opcode = &self.opcode,
                .payload_len = &self.payload_length,
                .extended_payload_len = &self.extended_payload_length,
            };
        }
        const InitOptions = struct {
            fin: bool = false,
            rsv1: u1 = 0,
            rsv2: u1 = 0,
            rsv3: u1 = 0,
            opcode: OpCode,
            masking_key: ?MaskingKey = null,
            app_data: AppData,
            ext_data: ?ExtData = null,
            allocator: Allocator,
        };

        pub fn init(opts: InitOptions)
        // AppData.Error!Self
        !Self {
            var app_data_bytes: []u8 = try opts.app_data.serialize(opts.allocator);
            var ext_data_bytes: ?[]u8 = null;
            defer {
                opts.allocator.free(app_data_bytes);
                if (ext_data_bytes) |b| {
                    opts.allocator.free(b);
                }
            }

            var opcode: OpCode, var allocator: Allocator, var rsv1: u1, var rsv2: u1, var rsv3: u1 = .{
                opts.opcode,
                opts.allocator,
                opts.rsv1,
                opts.rsv2,
                opts.rsv3,
            };

            if (opts.ext_data) |d| {
                const ext_data_frame_ctx = ExtData.Context.Create{
                    .rsv1 = &rsv1,
                    .rsv2 = &rsv2,
                    .rsv3 = &rsv3,
                    .opcode = &opcode,
                    .app_data = &app_data_bytes,
                    .allocator = &allocator,
                };
                ext_data_bytes = try d.create(ext_data_frame_ctx);
            }

            const len: usize = app_data_bytes.len + if (ext_data_bytes) |b| b.len else 0;

            var payload: []u8 = undefined;

            if (ext_data_bytes) |bytes| {
                payload =
                    try std.mem.concat(allocator, u8, &[2][]u8{ bytes, app_data_bytes });
            } else {
                payload = try allocator.dupe(u8, app_data_bytes);
            }

            if (opts.masking_key) |k| {
                mask_data(k, &payload);
            }

            var extended_payload_length: ?ExtendedPayloadLength = null;
            const payload_length: u7 = blk: {
                switch (len) {
                    0...125 => break :blk @as(u7, @intCast(len)),
                    126...65535 => {
                        extended_payload_length = ExtendedPayloadLength{ .sixteen = @as(u16, @intCast(len)) };
                        break :blk @as(u7, 126);
                    },
                    else => {
                        extended_payload_length = ExtendedPayloadLength{ .sixtyfour = @as(u64, @intCast(len)) };
                        break :blk @as(u7, 127);
                    },
                }
            };

            return Self{
                .fin = if (opts.fin) 1 else 0,
                .rsv1 = rsv1,
                .rsv2 = rsv2,
                .rsv3 = rsv3,
                .mask = if (opts.masking_key) |_| 1 else 0,
                .opcode = opcode,
                .payload_length = payload_length,
                .extended_payload_length = extended_payload_length,
                .masking_key = opts.masking_key,
                ._payload_data = payload,
                .allocator = allocator,
            };
        }

        /// Serialize `Frame` to `[]u8`
        pub fn serialize(self: Self) Allocator.Error![]u8 {
            std.log.warn("writing frame to bytes: {any}\n", .{self});
            const size = self.get_size();
            std.log.warn("frame has {} bytes in arr\n", .{size});
            var arr = try self.allocator.alloc(u8, size);
            var idx: usize = 0;

            const first_byte =
                ((@as(u8, @intCast(self.fin)) << 7) |
                (@as(u8, @intCast(self.rsv1)) << 6) |
                (@as(u8, @intCast(self.rsv2)) << 5) |
                (@as(u8, @intCast(self.rsv3)) << 4) |
                (@as(u8, @intFromEnum(self.opcode)) << 0));
            arr[idx] = first_byte;
            std.log.warn("first byte: {b}\n", .{first_byte});
            idx += 1;

            const second_byte =
                @as(u8, @intCast(self.mask)) << 7 |
                @as(u8, self.payload_length);
            arr[idx] = second_byte;
            std.log.warn("second byte: {b}\n", .{second_byte});
            idx += 1;

            if (self.extended_payload_length) |l| {
                switch (l) {
                    .sixteen => |val| {
                        var buf = std.mem.zeroes([2]u8);
                        std.mem.writeInt(u16, &buf, val, .big);
                        for (buf) |v| {
                            arr[idx] = v;
                            idx += 1;
                        }
                    },
                    .sixtyfour => |val| {
                        var buf = std.mem.zeroes([8]u8);
                        std.mem.writeInt(u64, &buf, val, .big);
                        for (buf) |v| {
                            arr[idx] = v;
                            idx += 1;
                        }
                    },
                }
            }

            if (self.masking_key) |k| {
                for (k) |byte| {
                    arr[idx] = byte;
                    idx += 1;
                }
            }

            for (self._payload_data) |byte| {
                arr[idx] = byte;
                idx += 1;
            }

            return arr;
        }

        fn get_size(self: Self) usize {
            var acc: usize = Self.INITIAL_READ_SIZE / 8;
            if (self.masking_key) |k| {
                acc += @sizeOf(@TypeOf(k));
            }
            // for payload len (u7) + mask flag (u1)
            acc += 1;
            if (self.extended_payload_length) |ext| {
                switch (ext) {
                    .sixteen => |l| {
                        std.debug.assert(self.payload_length == 126);
                        acc += 16 / 8;
                        acc += l;
                    },
                    .sixtyfour => |l| {
                        std.debug.assert(self.payload_length == 127);
                        acc += 64 / 8;
                        acc += l;
                    },
                }
            } else {
                acc += self.payload_length;
            }
            return acc;
        }

        pub fn read(reader: anytype, allocator: Allocator) !Self {
            const first_byte: u8 = (try reader.readBytesNoEof(1))[0];
            const second_byte: u8 = (try reader.readBytesNoEof(1))[0];
            std.log.debug("first byte: {b}\nsecond: {b}\n", .{ first_byte, second_byte });

            // https://www.geeksforgeeks.org/extract-bits-in-c/
            const fin: u1 = @truncate((first_byte >> 0) & 1 << 0);
            const rsv1: u1 = @truncate((first_byte >> 1) & 1 << 1);
            const rsv2: u1 = @truncate((first_byte >> 2) & 1 << 2);
            const rsv3: u1 = @truncate((first_byte >> 3) & 1 << 3);

            const opcode_int: u4 = @intCast(first_byte & 0x0F);
            const opcode: OpCode = @enumFromInt(opcode_int);
            const mask: u1 = @truncate(second_byte >> 7);
            const payload_size: u7 = @truncate(second_byte & 0x7F);

            std.log.debug(
                \\ fin: {d}
                \\ rsv1: {d}
                \\ rsv2: {d}
                \\ rsv3: {d}
                \\ opcode: {any}
                \\ mask: {d}
                \\ payload_size: {d}
            , .{
                fin,
                rsv1,
                rsv2,
                rsv3,
                opcode,
                mask,
                payload_size,
            });
            const size = if (mask == 1) payload_size + @bitSizeOf(MaskingKey) / 8 else payload_size;
            var rest_bytes = try allocator.alloc(u8, size);
            defer allocator.free(rest_bytes);
            const read_amt = try reader.read(rest_bytes);
            std.debug.assert(read_amt == size);

            const masking_key: ?MaskingKey = blk: {
                if (mask == 1) {
                    var k: [4]u8 = std.mem.zeroes([4]u8);
                    @memcpy(&k, rest_bytes[0..4]);
                    break :blk k;
                } else {
                    break :blk null;
                }
            };
            std.log.debug("masking key: {any}\n", .{masking_key});
            var payload = if (masking_key) |_| rest_bytes[4..] else rest_bytes;
            if (masking_key) |k| {
                mask_data(k, &payload);
            }
            std.log.debug("payload: {s}\n", .{payload});

            return Self{
                .fin = fin,
                .rsv1 = rsv1,
                .rsv2 = rsv2,
                .rsv3 = rsv3,
                .mask = mask,
                .opcode = opcode,
                .payload_length = payload_size,
                .extended_payload_length = null,
                .masking_key = masking_key,
                ._payload_data = payload,
                .allocator = allocator,
            };
        }
    };
}
