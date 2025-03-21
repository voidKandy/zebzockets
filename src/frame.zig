const std = @import("std");
const Allocator = std.mem.Allocator;

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

pub const PayloadData = struct {
    application_data: []u8,
    extension_data: []u8,

    const Builder = struct {
        app_data: ?[]u8 = null,
        ext_data: ?[]u8 = null,
        masking_key: ?MaskingKey = null,

        pub fn mask(self: Builder, key: MaskingKey) Builder {
            return Builder{
                .app_data = self.app_data,
                .ext_data = self.ext_data,
                .masking_key = key,
            };
        }
        pub fn application_data(self: Builder, data: []u8) Builder {
            return Builder{
                .app_data = data,
                .ext_data = self.ext_data,
                .masking_key = self.masking_key,
            };
        }
        pub fn extension_data(self: Builder, data: []u8) Builder {
            return Builder{
                .app_data = self.app_data,
                .ext_data = data,
                .masking_key = self.masking_key,
            };
        }

        /// Returns a built `PayloadData`, masking if needed
        pub fn finish(self: Builder) PayloadData {
            var app_data: []u8 = self.app_data orelse blk: {
                std.log.warn("building PayloadData without application data\n", .{});
                break :blk &[_]u8{};
            };
            var ext_data: []u8 = self.ext_data orelse blk: {
                std.log.warn("building PayloadData without extension data\n", .{});
                break :blk &[_]u8{};
            };
            if (self.masking_key) |k| {
                mask_data(k, &app_data);
                mask_data(k, &ext_data);
            }
            return PayloadData{
                .application_data = app_data,
                .extension_data = ext_data,
            };
        }
    };

    pub fn new() Builder {
        return Builder{};
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

const MaskingKey = [4]u8;
/// Masks data in-place, completely reversable by calling the same function again
/// Octet `i` of the `transformed-octet-i` is the XOR of
/// octet `i` of the original data `original-octet-i` with octet at
/// index `i` modulo 4 of the masking key `masking-key-octet-j`:
/// `j` = `i` MOD 4
/// `transformed-octet-i` = `original-octet-i` XOR `masking-key-octet-j`
fn mask_data(key: MaskingKey, data: *[]u8) void {
    for (0..data.len) |i| {
        data.*[i] ^= key[i % 4];
    }
}

pub fn ApplicationData(
    comptime Context: type,
    comptime Error: type,
    comptime ToBytesFn: *const fn (ctx: Context, a: Allocator) Error![]u8,
    comptime TrySerialize: *const fn (bytes: []u8, a: Allocator) Error!Context,
) type {
    return struct {
        ctx: Context,
        const Self = @This();

        pub inline fn to_bytes(self: Self, allocator: Allocator) Error![]u8 {
            return ToBytesFn(self.ctx, allocator);
        }

        pub inline fn try_serialize(bytes: []u8, allocator: Allocator) Error!Self {
            const ctx = try TrySerialize(bytes, allocator);
            return Self.from(ctx);
        }

        pub fn from(ctx: Context) Self {
            return Self{ .ctx = ctx };
        }
    };
}

/// Context needed by any extension
/// used to adjust fields as needed based on extension data
const ExtensionDataCreateCtx = struct {
    rsv1: *u1,
    rsv2: *u1,
    rsv3: *u1,
    opcode: *OpCode,
    app_data: *[]u8,
    allocator: *Allocator,
    const Self = @This();
};
const ExtensionDataReadCtx = struct {
    create_ctx: ExtensionDataCreateCtx,
    payload_len: *u7,
    extended_payload_len: *?ExtendedPayloadLength,
};
/// More likely to change once I'm more familiar with the needs of extensions
pub fn ExtensionData(
    comptime Context: type,
    comptime Error: type,
    comptime CreateFromContexts: *const fn (ctx: Context, d: ExtensionDataCreateCtx) Error!?[]u8,
    comptime TryRead: *const fn (bytes: []u8, read_ctx: ExtensionDataReadCtx) Error!Context,
) type {
    return struct {
        ctx: Context,
        const Self = @This();

        pub inline fn create(self: Self, d: ExtensionDataCreateCtx) Error!?[]u8 {
            return CreateFromContexts(self.ctx, d);
        }

        pub inline fn try_read(bytes: []u8, read_ctx: ExtensionDataReadCtx) Error!Self {
            const ctx = try TryRead(bytes, read_ctx);
            return Self.from(ctx);
        }

        pub fn from(ctx: Context) Self {
            return Self{ .ctx = ctx };
        }
    };
}

pub fn NewFrame(
    /// **MUST** be a type returned by the `ApplicationData` function
    AppData: anytype,
    /// **MUST** be a type returned by the `ExtensionData` function
    ExtData: anytype,
) type {
    return struct {
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
        application_data: []u8,
        extension_data: ?[]u8,

        const Self = @This();

        pub fn deinit(self: Self) void {
            self.allocator.free(self.application_data);
            if (self.extension_data) |d| {
                self.allocator.free(d);
            }
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
            var app_data_bytes = try opts.app_data.to_bytes(opts.allocator);
            var ext_data_bytes: ?[]u8 = null;

            var opcode: OpCode, var allocator: Allocator, var rsv1: u1, var rsv2: u1, var rsv3: u1 = .{
                opts.opcode,
                opts.allocator,
                opts.rsv1,
                opts.rsv2,
                opts.rsv3,
            };

            if (opts.ext_data) |d| {
                const ext_data_frame_ctx = ExtensionDataCreateCtx{
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
                .application_data = app_data_bytes,
                .extension_data = ext_data_bytes,
                .allocator = allocator,
            };
        }
    };
}

///   https://www.rfc-editor.org/rfc/rfc6455.html#section-5.2
///   It is important to note that the representation of this
///   data is binary, not ASCII characters.  As such, a field with a length
///   of 1 bit that takes values %x0 / %x1 is represented as a single bit
///   whose value is 0 or 1, not a full byte (octet) that stands for the
///   characters "0" or "1" in the ASCII encoding.
pub const Frame = struct {
    ///Indicates that this is the final fragment in a message.  The first fragment MAY also be the final fragment.
    fin: u1,
    ///   MUST be 0 unless an extension is negotiated that defines meanings
    ///   for non-zero values.  If a nonzero value is received and none of
    ///   the negotiated extensions defines the meaning of such a nonzero
    ///   value, the receiving endpoint MUST _Fail the WebSocket Connection_.
    rsv1: u1,
    rsv2: u1,
    rsv3: u1,
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
    payload_data: PayloadData,

    /// Size of all fields up until payload length + mask byte in bits
    /// fin (**u1**)
    /// rsv1 (**u1**)
    /// rsv2 (**u1**)
    /// rsv3 (**u1**)
    /// opcode (**u4**)
    pub const INITIAL_READ_SIZE: usize = 8;
    /// If masked, `PayloadData` should be masked *before* being passed to this function
    pub fn build(fin: bool, opcode: OpCode, payload_data: PayloadData, masking_key: ?MaskingKey) Frame {
        const len: usize = payload_data.extension_data.len + payload_data.application_data.len;
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
        const mask: u1 = if (masking_key) |_| 1 else 0;
        return Frame{
            .fin = if (fin) 1 else 0,
            .rsv1 = 0,
            .rsv2 = 0,
            .rsv3 = 0,
            .mask = mask,
            .opcode = opcode,
            .payload_length = payload_length,
            .extended_payload_length = extended_payload_length,
            .masking_key = masking_key,
            .payload_data = payload_data,
        };
    }

    /// size of frame in bytes
    fn get_size(frame: Frame) usize {
        var acc: usize = Frame.INITIAL_READ_SIZE / 8;
        if (frame.masking_key) |k| {
            acc += @sizeOf(@TypeOf(k));
        }
        // for payload len (u7) + mask flag (u1)
        acc += 1;
        if (frame.extended_payload_length) |ext| {
            switch (ext) {
                .sixteen => |l| {
                    std.debug.assert(frame.payload_length == 126);
                    acc += 16 / 8;
                    acc += l;
                },
                .sixtyfour => |l| {
                    std.debug.assert(frame.payload_length == 127);
                    acc += 64 / 8;
                    acc += l;
                },
            }
        } else {
            acc += frame.payload_length;
        }
        return acc;
    }

    /// Serialize `Frame` to `[]u8`
    pub fn as_bytes(frame: Frame, allocator: Allocator) Allocator.Error![]u8 {
        std.log.warn("writing frame to bytes: {any}\n", .{frame});
        const size = frame.get_size();
        std.log.warn("frame has {} bytes in arr\n", .{size});
        var arr = try allocator.alloc(u8, size);
        var idx: usize = 0;

        const first_byte =
            ((@as(u8, @intCast(frame.fin)) << 7) |
            (@as(u8, @intCast(frame.rsv1)) << 6) |
            (@as(u8, @intCast(frame.rsv2)) << 5) |
            (@as(u8, @intCast(frame.rsv3)) << 4) |
            (@as(u8, @intFromEnum(frame.opcode)) << 0));
        arr[idx] = first_byte;
        std.log.warn("first byte: {b}\n", .{first_byte});
        idx += 1;

        const second_byte =
            @as(u8, @intCast(frame.mask)) << 7 |
            @as(u8, frame.payload_length);
        arr[idx] = second_byte;
        std.log.warn("second byte: {b}\n", .{second_byte});
        idx += 1;

        if (frame.extended_payload_length) |l| {
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

        if (frame.masking_key) |k| {
            for (k) |byte| {
                arr[idx] = byte;
                idx += 1;
            }
        }

        for (frame.payload_data.application_data) |byte| {
            arr[idx] = byte;
            idx += 1;
        }
        for (frame.payload_data.extension_data) |byte| {
            arr[idx] = byte;
            idx += 1;
        }

        return arr;
    }

    // this reader could be constrained more but fuq it
    pub fn read(reader: anytype, allocator: Allocator) !Frame {
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

        const payload_data = PayloadData.new().application_data(payload).finish();

        return Frame{
            .fin = fin,
            .rsv1 = rsv1,
            .rsv2 = rsv2,
            .rsv3 = rsv3,
            .mask = mask,
            .opcode = opcode,
            .payload_length = payload_size,
            .extended_payload_length = null,
            .masking_key = masking_key,
            .payload_data = payload_data,
        };
    }
};

test "masking works" {
    const CaseDataSize: usize = 5;
    const Case = struct {
        data: [CaseDataSize]u8,
        expected: [CaseDataSize]u8,
        key: MaskingKey,
    };

    // chat gpt made these..
    // i might need to redo this test in case these are wrong
    const cases = [_]Case{
        Case{
            .data = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A },
            .expected = [_]u8{ 0xB8, 0x8F, 0x9A, 0xA5, 0x30 },
            .key = [4]u8{ 0xAA, 0xBB, 0xCC, 0xDD },
        },
        Case{
            .data = [_]u8{ 0xFF, 0xEE, 0xDD, 0xCC, 0xBB },
            .expected = [_]u8{ 0x55, 0x55, 0x11, 0x11, 0x11 },
            .key = [4]u8{ 0xAA, 0xBB, 0xCC, 0xDD },
        },
        Case{
            .data = [_]u8{
                0b00000001, 0b10110011, 0b11011101, 0b11001100, 0b10111011,
            },
            .key = [4]u8{
                0b10101010, 0b10111111, 0b10010000, 0b10110101,
            },
            .expected = [_]u8{
                0b10101011, 0b00001100, 0b01001101, 0b01111001, 0b00010001,
            },
        },
    };

    const allocator = std.testing.allocator;
    for (cases, 1..) |case, i| {
        var data = try allocator.alloc(u8, CaseDataSize);
        defer allocator.free(data);
        @memcpy(data, &case.data);

        mask_data(case.key, &data);
        try std.testing.expectEqualSlices(u8, &case.expected, data);
        std.log.warn("Case {d} Passed Initial Masking!\n", .{i});

        mask_data(case.key, &data);
        try std.testing.expectEqualSlices(u8, &case.data, data);
        std.log.warn("Case {d} Passed ReMasking!\n", .{i});
    }
}

test "build frame works" {
    const Case = struct {
        application_data_size: usize,
        extension_data_size: usize,
        masking_key: ?MaskingKey,
    };
    const allocator = std.testing.allocator;
    const opcode = OpCode.continuation;
    const cases = [_]Case{
        Case{ .application_data_size = 16, .extension_data_size = 16, .masking_key = null },
        Case{ .application_data_size = 256, .extension_data_size = 16, .masking_key = null },
        Case{ .application_data_size = 40000, .extension_data_size = 40000, .masking_key = null },
        Case{
            .application_data_size = 40000,
            .extension_data_size = 40000,
            .masking_key = null,
        },
        Case{
            .application_data_size = 40000,
            .extension_data_size = 40000,
            .masking_key = [4]u8{ 0xAA, 0xBB, 0xCC, 0xDD },
        },
    };

    for (cases, 1..) |case, i| {
        const expected_len = case.application_data_size + case.extension_data_size;
        const application_data = try allocator.alloc(u8, case.application_data_size);
        defer allocator.free(application_data);
        const extension_data = try allocator.alloc(u8, case.extension_data_size);
        defer allocator.free(extension_data);

        const pre_masked_data: ?PayloadData = blk: {
            _ = case.masking_key orelse break :blk null;
            std.log.warn("copying data for case to be masked: {d}\n", .{i});
            const cpy_app_data = try allocator.alloc(u8, application_data.len);
            const cpy_ext_data = try allocator.alloc(u8, extension_data.len);
            @memcpy(cpy_app_data, application_data);
            @memcpy(cpy_ext_data, extension_data);
            const cpy = PayloadData{
                .application_data = cpy_app_data,
                .extension_data = cpy_ext_data,
            };
            break :blk cpy;
        };

        const payload_data = blk: {
            var builder = PayloadData.new().application_data(application_data).extension_data(extension_data);
            if (case.masking_key) |k| {
                builder = builder.mask(k);
            }
            break :blk builder.finish();
        };

        var frame = Frame.build(false, opcode, payload_data, case.masking_key);
        if (frame.extended_payload_length) |extended_len| {
            switch (extended_len) {
                .sixteen => |l| {
                    try std.testing.expectEqual(frame.payload_length, 126);
                    try std.testing.expectEqual(l, expected_len);
                },
                .sixtyfour => |l| {
                    try std.testing.expectEqual(frame.payload_length, 127);
                    try std.testing.expectEqual(l, expected_len);
                },
            }
        } else {
            try std.testing.expectEqual(frame.payload_length, expected_len);
        }
        if (pre_masked_data) |pre_data| {
            const key = frame.masking_key orelse std.debug.panic("expected case {d} to have a masking key\n", .{i});
            std.log.warn("validating masked data\n", .{});
            defer allocator.free(pre_data.application_data);
            defer allocator.free(pre_data.extension_data);
            mask_data(key, &frame.payload_data.application_data);
            try std.testing.expectEqualSlices(u8, pre_data.application_data, frame.payload_data.application_data);
            std.log.warn("application data masked as expected!\n", .{});
            mask_data(key, &frame.payload_data.extension_data);
            try std.testing.expectEqualSlices(u8, pre_data.extension_data, frame.payload_data.extension_data);
            std.log.warn("extension data masked as expected!\n", .{});
        }
        std.log.warn(
            \\Frame OK:
            \\Opcode: {any}
            \\Mask: {d}
            \\Masking Key: {any}
            \\Payload Len: {d}
            \\Extended Payload Len: {any}
            \\
        , .{ frame.opcode, frame.mask, frame.masking_key, frame.payload_length, frame.extended_payload_length });
    }
}

test "Frame.as_bytes() works correctly" {
    const allocator = std.testing.allocator;

    const Case = struct {
        fin: bool,
        opcode: OpCode,
        application_data: []u8,
        mask: ?MaskingKey,
        /// will be masked in the process of testing pass in unmasked data
        expected: []const u8,
    };

    const empty_payload = try allocator.alloc(u8, 0);
    defer allocator.free(empty_payload);

    const small_payload = try allocator.alloc(u8, 3);
    defer allocator.free(small_payload);
    small_payload[0] = 1;
    small_payload[1] = 2;
    small_payload[2] = 3;

    const string_payload = try allocator.alloc(u8, 5);
    defer allocator.free(string_payload);
    const string_payload_val =
        "hello";
    for (string_payload_val, 0..) |c, i| {
        string_payload[i] = c;
    }

    const masked_payload = try allocator.alloc(u8, 4);
    defer allocator.free(masked_payload);
    masked_payload[0] = 1;
    masked_payload[1] = 2;
    masked_payload[2] = 3;
    masked_payload[3] = 4;

    const extended_payload = try allocator.alloc(u8, 256);
    defer allocator.free(extended_payload);
    @memset(extended_payload, 0x55);
    extended_payload[0] = 0x39;
    extended_payload[extended_payload.len - 1] = 0x86;

    const cases = [_]Case{
        Case{
            .fin = false,
            .opcode = OpCode.continuation,
            .application_data = empty_payload,
            .mask = null,
            .expected = &[_]u8{ 0x00, 0x00 },
        },
        Case{
            .fin = true,
            .opcode = OpCode.text,
            .application_data = string_payload,
            .mask = null,
            .expected = &[_]u8{
                0b10000001,        0b00000101,
                string_payload[0], string_payload[1],
                string_payload[2], string_payload[3],
                string_payload[4],
            },
        },
        Case{
            .fin = true,
            .opcode = OpCode.text,
            .application_data = small_payload,
            .mask = null,
            .expected = &[_]u8{ 0x81, 0x03, 0x01, 0x02, 0x03 },
        },
        Case{
            .fin = true,
            .opcode = OpCode.binary,
            .application_data = masked_payload,
            .mask = [4]u8{ 0xAA, 0xBB, 0xCC, 0xDD },
            .expected = &[_]u8{ 0x82, 0x84, 0xAA, 0xBB, 0xCC, 0xDD, 0x01, 0x02, 0x03, 0x04 },
        },
        Case{
            .fin = false,
            .opcode = OpCode.text,
            .application_data = extended_payload,
            .mask = null,
            .expected = blk: {
                var buf: [260]u8 = undefined;
                buf[0] = 0x01;
                buf[1] = 0x7E; // 126 in payload len + 0 mask
                buf[2] = 0x01; // extended payload length
                buf[3] = 0x00; // extended payload length
                @memset(buf[4..], 0x55);
                buf[4] = 0x39;
                buf[259] = 0x86;
                break :blk &buf;
            },
        },
    };

    for (cases, 1..) |case, i| {
        const payload = blk: {
            var b = PayloadData.new().application_data(case.application_data);
            if (case.mask) |key| {
                b = b.mask(key);
            }
            break :blk b.finish();
        };
        const frame = Frame.build(case.fin, case.opcode, payload, case.mask);
        var expected: []u8 = try allocator.alloc(u8, case.expected.len);
        defer allocator.free(expected);
        @memcpy(expected, case.expected);
        if (case.mask) |key| {
            std.log.warn("masking expected data\n", .{});
            const offset: usize =
                frame.get_size() - case.application_data.len;
            var slice = expected[offset..];
            mask_data(key, &slice);
        }
        const bytes = try frame.as_bytes(allocator);
        defer allocator.free(bytes);

        try std.testing.expectEqualSlices(u8, expected, bytes);
        std.log.warn("Case {d} passed", .{i});
    }
}

const SizedByteDataError =
    error{ Allocator, SizeMismatch };
const SizedByteData = ApplicationData([64]u8, SizedByteDataError, struct {
    fn to_bytes(in: [64]u8, allocator: Allocator) SizedByteDataError![]u8 {
        const bytes = allocator.alloc(u8, in.len) catch return error.Allocator;
        std.mem.copyForwards(u8, bytes, &in);
        return bytes;
    }
}.to_bytes, struct {
    fn try_ser(bytes: []u8, a: Allocator) SizedByteDataError![64]u8 {
        defer a.free(bytes);
        if (bytes.len != 64) {
            return error.SizeMismatch;
        }
        var buf: [64]u8 = undefined;
        @memset(&buf, 0);
        @memcpy(&buf, bytes[0..]);
        // for (bytes, 0..) |b, i| {
        //     buf[i] = b;
        // }
        return buf;
    }
}.try_ser);
const NullExt = ExtensionData([0]u1, Allocator.Error, struct {
    fn create(in: [0]u1, ext_ctx: ExtensionDataCreateCtx) Allocator.Error!?[]u8 {
        _ = ext_ctx;
        _ = in;
        return null;
    }
}.create, struct {
    fn try_read(bytes: []u8, ctx: ExtensionDataReadCtx) Allocator.Error![0]u1 {
        _ = ctx;
        _ = bytes;
        return .{};
    }
}.try_read);

const PlaceDataError =
    error{ Allocator, Json };
const PlaceData = ApplicationData(
    Place,
    PlaceDataError,
    struct {
        fn to_bytes(in: Place, a: Allocator) PlaceDataError![]u8 {
            return std.json.stringifyAlloc(a, in, .{}) catch |e| {
                std.log.err("failed to stringify place: {}\n", .{e});
                return error.Allocator;
            };
        }
    }.to_bytes,

    struct {
        fn try_ser(bytes: []u8, a: Allocator) PlaceDataError!Place {
            const parsed = std.json.parseFromSlice(
                Place,
                a,
                bytes,
                .{},
            ) catch |e| {
                std.log.err("failed to parse place: {}\n", .{e});
                return error.Json;
            };
            defer parsed.deinit();
            return parsed.value;
        }
    }.try_ser,
);
const Place = struct { lat: f32, long: f32 };

test "newframe" {
    const allocator = std.testing.allocator;
    const data = SizedByteData.from(std.mem.zeroes([64]u8));
    const byte_frame = try NewFrame(SizedByteData, NullExt).init(.{ .opcode = OpCode.text, .app_data = data, .allocator = allocator });
    defer byte_frame.deinit();
    std.log.warn("made byte frame: {any}\n", .{byte_frame});

    const place = PlaceData.from(Place{ .lat = 0.5, .long = 4.56 });
    const json_frame = try NewFrame(PlaceData, NullExt).init(.{ .opcode = OpCode.text, .app_data = place, .allocator = allocator });
    defer json_frame.deinit();
    std.log.warn("made json frame: {any}\n", .{json_frame});
}
