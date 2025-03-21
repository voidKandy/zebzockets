const std = @import("std");
const Allocator = std.mem.Allocator;
const zz = @import("zebzockets");
const ApplicationData = zz.frame.ApplicationData;
const Frame = zz.frame.Frame;
const MaskingKey = zz.frame.MaskingKey;
const OpCode = zz.frame.OpCode;
const ExtensionData = zz.frame.ExtensionData;
const ExtDataCtx = zz.frame.ExtDataCtx;

const NullExt = ExtensionData([0]u1, Allocator.Error, struct {
    fn create(in: [0]u1, ctx: ExtDataCtx([0]u1).Create) Allocator.Error!?[]u8 {
        _ = ctx;
        _ = in;
        return null;
    }
}.create, struct {
    fn try_read(bytes: []u8, ctx: ExtDataCtx([0]u1).Read) Allocator.Error!ExtDataCtx([0]u1).ReadResult {
        _ = ctx;
        _ = bytes;
        return .{ .amt = 0, .inner = .{} };
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
                std.log.err("failed to stringify place: {?}\n", .{e});
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
                std.log.err("failed to parse place: {?}\n", .{e});
                return error.Json;
            };
            defer parsed.deinit();
            return parsed.value;
        }
    }.try_ser,
);
const Place = struct { lat: f32, long: f32 };

fn TestCase(
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
            if (!std.meta.eql(payload.app_data, case.app_data)) {
                std.debug.panic("did not get expected payload app data value\nExpected: {?}\nGot: {?}\n", .{ payload.app_data, case.app_data });
            }
            if (!std.meta.eql(payload.ext_data, case.ext_data)) {
                std.debug.panic("did not get expected payload ext data value\nExpected: {?}\nGot: {?}\n", .{ payload.ext_data, case.ext_data });
            }
            const bytes = try frame.as_bytes(allocator);
            defer allocator.free(bytes);

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
        fn to_bytes(in: [SizedByteDataSize]u8, allocator: Allocator) SizedByteDataError![]u8 {
            const bytes = allocator.alloc(u8, in.len) catch return error.Allocator;
            std.mem.copyForwards(u8, bytes, &in);
            return bytes;
        }
    }.to_bytes, struct {
        fn try_ser(bytes: []u8, a: Allocator) SizedByteDataError![SizedByteDataSize]u8 {
            defer a.free(bytes);
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
    }.try_ser);

    const allocator = std.testing.allocator;

    try TestCase(SizedByteData, NullExt).run_test(.{
        .fin = false,
        .opcode = OpCode.text,
        .app_data = SizedByteData.from(blk: {
            var arr = std.mem.zeroes([SizedByteDataSize]u8);
            arr[0] = 0x39;
            arr[SizedByteDataSize - 1] = 0x86;
            break :blk arr;
        }),
        .ext_data = NullExt.from(.{}),
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
