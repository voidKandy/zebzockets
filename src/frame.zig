const std = @import("std");

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
const OpCode = enum(u4) {
    // non-control frames
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    undefined_non_control,
    // control frames
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
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

const PayloadData = struct {
    application_data: []u8,
    extension_data: []u8,

    const Builder = struct {
        app_data: ?[]u8 = null,
        ext_data: ?[]u8 = null,
        masking_key: ?MaskingKey = null,

        fn mask(self: Builder, key: MaskingKey) Builder {
            return Builder{
                .app_data = self.app_data,
                .ext_data = self.ext_data,
                .masking_key = key,
            };
        }
        fn application_data(self: Builder, data: []u8) Builder {
            return Builder{
                .app_data = data,
                .ext_data = self.ext_data,
                .masking_key = self.masking_key,
            };
        }
        fn extension_data(self: Builder, data: []u8) Builder {
            return Builder{
                .app_data = self.app_data,
                .ext_data = data,
                .masking_key = self.masking_key,
            };
        }

        /// Returns a built `PayloadData`, masking if needed
        fn finish(self: Builder) PayloadData {
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

    fn new() Builder {
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

///   https://www.rfc-editor.org/rfc/rfc6455.html#section-5.2
///   It is important to note that the representation of this
///   data is binary, not ASCII characters.  As such, a field with a length
///   of 1 bit that takes values %x0 / %x1 is represented as a single bit
///   whose value is 0 or 1, not a full byte (octet) that stands for the
///   characters "0" or "1" in the ASCII encoding.
const Frame = struct {
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

    /// Size of all fields up until payload length
    pub const INITIAL_READ_SIZE: usize = 16;
    /// If masked, `PayloadData` should be masked *before* being passed to this function
    pub fn build(opcode: OpCode, masking_key: ?MaskingKey, payload_data: PayloadData) Frame {
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
            .fin = 0,
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

        var frame = Frame.build(opcode, case.masking_key, payload_data);
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
