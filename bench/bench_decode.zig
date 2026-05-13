//! Decode-pipeline benchmark for zig-frame-protocol.
//!
//! Measures the full decode path — `fp.decode` strips the delimiter, COBS-
//! decodes, then parses the header / verifies CRC32 — at three payload sizes
//! (16 B / 256 B / 1 KiB). Throughput is reported in *payload* bytes/sec
//! (matching the encode benchmark).
//!
//! Timing: see `bench_encode.zig` for the `std.os.linux.clock_gettime`
//! rationale.

const std = @import("std");
const fp = @import("frame_protocol");

inline fn nanos() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.nsec));
}

const Size = struct {
    label: []const u8,
    bytes: usize,
    iters: usize,
};

const sizes = [_]Size{
    .{ .label = "16B", .bytes = 16, .iters = 2_000_000 },
    .{ .label = "256B", .bytes = 256, .iters = 1_000_000 },
    .{ .label = "1KiB", .bytes = 1024, .iters = 500_000 },
};

const warmup_iters: usize = 1_000;
const max_payload: usize = fp.max_payload_len;

pub fn main() !void {
    var payload_buf: [max_payload]u8 = undefined;
    var enc_scratch: [fp.packetLen(max_payload)]u8 = undefined;
    var wire_buf: [fp.maxEncodedLen(max_payload)]u8 = undefined;
    var dec_scratch: [fp.maxEncodedLen(max_payload)]u8 = undefined;

    var rng = std.Random.DefaultPrng.init(0xF7A_E1C0_DE);
    rng.random().bytes(&payload_buf);

    std.debug.print("# zig-frame-protocol bench: decode (ReleaseFast, MONOTONIC ns)\n", .{});

    for (sizes) |s| {
        const payload = payload_buf[0..s.bytes];

        // Build one wire frame outside the measurement window.
        const wire_len = try fp.encode(&wire_buf, &enc_scratch, 0x42, 1, 0xCAFE, payload);
        const wire = wire_buf[0..wire_len];

        // Warm-up — discarded.
        var w: usize = 0;
        while (w < warmup_iters) : (w += 1) {
            const frame = try fp.decode(wire, &dec_scratch);
            std.mem.doNotOptimizeAway(frame.kind);
            std.mem.doNotOptimizeAway(frame.payload.len);
        }

        const t0 = nanos();
        var i: usize = 0;
        while (i < s.iters) : (i += 1) {
            const frame = try fp.decode(wire, &dec_scratch);
            std.mem.doNotOptimizeAway(frame.kind);
            std.mem.doNotOptimizeAway(frame.payload.len);
        }
        const total_ns = nanos() - t0;

        const ns_per_op = total_ns / s.iters;
        const total_bytes: u128 = @as(u128, s.bytes) * @as(u128, s.iters);
        const mbps: u128 = (total_bytes * 1000) / @max(@as(u128, total_ns), 1);

        std.debug.print(
            "bench=decode size={s} bytes={d} op=DECODE iters={d} total_ns={d} ns_per_op={d} MBps={d}\n",
            .{ s.label, s.bytes, s.iters, total_ns, ns_per_op, mbps },
        );
    }
}
