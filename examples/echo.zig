//! Minimal zig-frame-protocol example — encode a frame, decode it back,
//! verify the result.
//!
//! Build: `zig build example-echo`
//! Run:   `./zig-out/bin/example-echo`

const std = @import("std");
const fp = @import("frame_protocol");

pub fn main() !void {
    const payload = "sensor-id=42 temp=72.3 humidity=0.41";

    var scratch: [fp.packetLen(payload.len)]u8 = undefined;
    var wire: [fp.maxEncodedLen(payload.len)]u8 = undefined;

    const wire_len = try fp.encode(
        &wire,
        &scratch,
        0x10,                 // kind (caller-defined: 0x10 = sensor reading)
        12345,                // sequence number
        1_715_000_000_000,    // timestamp (ms)
        payload,
    );

    std.debug.print("payload  ({d:>3} bytes): \"{s}\"\n", .{ payload.len, payload });
    std.debug.print("wire     ({d:>3} bytes): ", .{wire_len});
    for (wire[0..wire_len]) |b| std.debug.print("{x:0>2} ", .{b});
    std.debug.print("\n", .{});

    // Verify the wire bytes contain no internal zeros (except the trailing
    // 0x00 frame delimiter).
    for (wire[0 .. wire_len - 1]) |b| std.debug.assert(b != 0);
    std.debug.assert(wire[wire_len - 1] == 0);

    var dec_scratch: [fp.maxEncodedLen(payload.len)]u8 = undefined;
    const frame = try fp.decode(wire[0..wire_len], &dec_scratch);

    std.debug.print("\ndecoded:\n", .{});
    std.debug.print("  kind     = 0x{x:0>2}\n", .{frame.kind});
    std.debug.print("  sequence = {d}\n", .{frame.sequence});
    std.debug.print("  node_ms  = {d}\n", .{frame.node_ms});
    std.debug.print("  payload  = \"{s}\"\n", .{frame.payload});

    std.debug.assert(frame.kind == 0x10);
    std.debug.assert(frame.sequence == 12345);
    std.debug.assert(std.mem.eql(u8, payload, frame.payload));
    std.debug.print("\nroundtrip OK — wire format v1, CRC32 validated, COBS unwrapped\n", .{});
}
