const std = @import("std");
const Allocator = std.mem.Allocator;
const zz = @import("zebzockets");
const ApplicationData = zz.frame.ApplicationData;
const Frame = zz.frame.Frame;
const MaskingKey = zz.frame.MaskingKey;
const OpCode = zz.frame.OpCode;
const ExtensionData = zz.frame.ExtensionData;
const ExtDataCtx = zz.frame.ExtDataCtx;
const NullExt = zz.frame.NullExt;

/// For running tests with the `SizedByteData` type
fn BytesTestCase(
    AppData: anytype,
    ExtData: anytype,
) type {
    return struct {
        fin: bool,
        app_data: AppData,
        ext_data: ?ExtData,
        masking_key: ?MaskingKey,
        opcode: OpCode,
        expected_bytes: []const u8,
        const Self = @This();
        const MyFrame =
            Frame(AppData, ExtData);

        fn run_test(case: Self, allocator: std.mem.Allocator) !void {
            std.log.warn("TESTING {s}\n", .{@typeName(AppData)});
            const frame = try MyFrame.init(.{
                .fin = case.fin,
                .opcode = case.opcode,
                .app_data = case.app_data,
                .ext_data = case.ext_data,
                .allocator = allocator,
            });
            defer frame.deinit();

            const payload = try frame.payload_data();
            defer payload.deinit(frame.allocator);

            for (payload.app_data.inner, 0..) |b, i| {
                if (b != case.app_data.inner[i]) {
                    std.debug.panic("did not get expected payload app data value\nExpected: {any}\nGot:      {any}\n", .{ case.app_data.inner, payload.app_data.inner });
                }
            }
            if (!std.meta.eql(payload.ext_data, case.ext_data)) {
                std.debug.panic("did not get expected payload ext data value\nExpected: {?}\nGot:      {?}\n", .{ case.ext_data, payload.ext_data });
            }
            const bytes = try frame.serialize();
            defer allocator.free(bytes);

            try std.testing.expectEqualSlices(u8, case.expected_bytes, bytes);
            std.log.warn("Case PASSED\n", .{});
        }
    };
}

/// For running tests with the `JsonAppData` type
fn JsonTestCase(
    payload: []const u8,
    /// Type to be wrapped by `JsonAppData`
    AppDataType: type,
    ExtData: anytype,
) type {
    return struct {
        const AppData = zz.frame.JsonAppData(AppDataType, .{}, .{});
        const Self = @This();
        const MyFrame =
            Frame(AppData, ExtData);
        fin: bool,
        app_data: AppData,
        ext_data: ?ExtData,
        masking_key: ?MaskingKey,
        opcode: OpCode,
        expected_bytes: []u8,
        allocator: Allocator,

        fn deinit(self: Self) void {
            self.allocator.free(self.expected_bytes);
            self.app_data.inner.deinit();
        }
        /// only pass the non-application data expected bytes
        /// Since the payload is known at comptime, the rest of expected bytes are created here
        fn init(allocator: Allocator, is_fin: bool, op: OpCode, key: ?MaskingKey, ext: ?ExtData, expected: []const u8) !Self {
            const app_data = try std.json.parseFromSlice(
                AppDataType,
                allocator,
                payload,
                .{},
            );

            var expected_bytes = try allocator.alloc(u8, expected.len + payload.len);

            for (expected, 0..) |byte, i| {
                expected_bytes[i] = byte;
            }
            for (payload, 0..) |byte, i| {
                expected_bytes[i + expected.len] = byte;
            }

            return Self{
                .fin = is_fin,
                .app_data = AppData.from(app_data),
                .ext_data = ext,
                .masking_key = key,
                .opcode = op,
                .expected_bytes = expected_bytes,
                .allocator = allocator,
            };
        }

        fn run_test(case: Self) !void {
            std.log.warn("TESTING {s}\n", .{@typeName(AppData)});
            const frame = try MyFrame.init(.{
                .fin = case.fin,
                .opcode = case.opcode,
                .app_data = case.app_data,
                .ext_data = case.ext_data,
                .allocator = case.allocator,
            });
            defer frame.deinit();

            const payload_data = try frame.payload_data();
            defer payload_data.deinit(frame.allocator);

            if (!std.meta.eql(payload_data.app_data.inner.value, case.app_data.inner.value)) {
                std.debug.panic("did not get expected payload app data value\nExpected: {?}\nGot: {?}\n", .{ payload_data.app_data, case.app_data });
            }
            if (payload_data.ext_data) |ext| {
                try std.testing.expect(case.ext_data != null);
                if (!std.meta.eql(ext.inner, case.ext_data.?.inner)) {
                    std.debug.panic("did not get expected payload ext data value\nExpected: {?}\nGot: {?}\n", .{ payload_data.ext_data, case.ext_data });
                }
            }

            const bytes = try frame.serialize();
            defer case.allocator.free(bytes);

            try std.testing.expectEqualSlices(u8, case.expected_bytes, bytes);
            std.log.warn("Case PASSED\n", .{});
        }
    };
}
test "SizedByteData" {
    const SizedByteDataError =
        error{ Allocator, SizeMismatch };
    const SizedByteDataSize = 64;
    const SizedByteData = ApplicationData([SizedByteDataSize]u8, SizedByteDataError, struct {
        fn ser(in: [SizedByteDataSize]u8, allocator: Allocator) SizedByteDataError![]u8 {
            const bytes = allocator.alloc(u8, in.len) catch return error.Allocator;
            std.mem.copyForwards(u8, bytes, &in);
            return bytes;
        }
    }.ser, struct {
        fn deser(bytes: []u8, a: Allocator) SizedByteDataError![SizedByteDataSize]u8 {
            _ = a;
            if (bytes.len != SizedByteDataSize) {
                return error.SizeMismatch;
            }
            var buf: [SizedByteDataSize]u8 = undefined;
            @memset(&buf, 0);
            @memcpy(&buf, bytes[0..]);
            // for (bytes, 0..) |b, i| {
            //     buf[i] = b;
            // }
            return buf;
        }
    }.deser, null);

    const allocator = std.testing.allocator;

    try BytesTestCase(SizedByteData, NullExt).run_test(.{
        .fin = false,
        .opcode = OpCode.text,
        .app_data = SizedByteData.from(blk: {
            var arr = std.mem.zeroes([SizedByteDataSize]u8);
            arr[0] = 0x39;
            arr[SizedByteDataSize - 1] = 0x86;
            break :blk arr;
        }),
        .ext_data = null,
        .masking_key = null,
        .expected_bytes = &blk: {
            var buf: [SizedByteDataSize + 2]u8 = undefined;
            buf[0] = 0x01;
            buf[1] = @as(u8, SizedByteDataSize);
            @memset(buf[2..], 0x0);
            buf[2] = 0x39;
            buf[SizedByteDataSize + 1] = 0x86;
            break :blk buf;
        },
    }, allocator);

    try BytesTestCase(SizedByteData, NullExt).run_test(.{
        .fin = true,
        .opcode = OpCode.text,
        .app_data = SizedByteData.from(blk: {
            var arr: [SizedByteDataSize]u8 = undefined;
            @memset(&arr, 0x55);
            arr[0] = 0x39;
            arr[SizedByteDataSize - 1] = 0x86;
            break :blk arr;
        }),
        .ext_data = null,
        .masking_key = null,
        .expected_bytes = &blk: {
            var buf: [SizedByteDataSize + 2]u8 = undefined;
            buf[0] = 0x81;
            buf[1] = @as(u8, SizedByteDataSize);
            @memset(buf[2..], 0x55);
            buf[2] = 0x39;
            buf[SizedByteDataSize + 1] = 0x86;
            break :blk buf;
        },
    }, allocator);

    var test_transparent_arr: []u8 = try allocator.alloc(u8, 10);
    defer allocator.free(test_transparent_arr);
    @memset(test_transparent_arr, 0x00);
    test_transparent_arr[0] = 0x39;
    test_transparent_arr[10 - 1] = 0x86;
    try BytesTestCase(zz.frame.TransparentAppData, NullExt).run_test(.{
        .fin = true,
        .opcode = OpCode.text,
        .app_data = zz.frame.TransparentAppData.from(test_transparent_arr),
        .ext_data = null,
        .masking_key = null,
        .expected_bytes = &blk: {
            var buf: [10 + 2]u8 = undefined;
            buf[0] = 0x81;
            buf[1] = @as(u8, 10);
            @memset(buf[2..], 0x00);
            buf[2] = 0x39;
            buf[10 + 1] = 0x86;
            break :blk buf;
        },
    }, allocator);
}

test "JsonAppData" {
    const allocator = std.testing.allocator;
    const Place = struct { long: u32, lat: u32 };

    const case = try JsonTestCase("{\"long\":74,\"lat\":40}", Place, NullExt)
        .init(allocator, false, OpCode.text, null, null, blk: {
        var buf: [2]u8 = undefined;
        buf[0] = 0x01;
        buf[1] = 0x14;
        break :blk &buf;
    });
    defer case.deinit();

    try case.run_test();
}

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

        zz.frame.mask_data(case.key, &data);
        try std.testing.expectEqualSlices(u8, &case.expected, data);
        std.log.warn("Case {d} Passed Initial Masking!\n", .{i});

        zz.frame.mask_data(case.key, &data);
        try std.testing.expectEqualSlices(u8, &case.data, data);
        std.log.warn("Case {d} Passed ReMasking!\n", .{i});
    }
}
