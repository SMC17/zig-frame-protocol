//! End-to-end roundtrip benchmark for zig-frame-protocol.
//!
//! Measures one encode followed by one decode per iteration, at a 256-byte
//! payload — representative of small sensor / telemetry frames. Reports both
//! ns/op and packets/sec, which is the number callers care about for "how
//! many sensor frames per second can this link push."
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

const payload_size: usize = 256;
const warmup_iters: usize = 1_000;
const iters: usize = 1_000_000;

pub fn main() !void {
    var payload: [payload_size]u8 = undefined;
    var enc_scratch: [fp.packetLen(payload_size)]u8 = undefined;
    var wire: [fp.maxEncodedLen(payload_size)]u8 = undefined;
    var dec_scratch: [fp.maxEncodedLen(payload_size)]u8 = undefined;

    var rng = std.Random.DefaultPrng.init(0xF7A_E1C0_DE);
    rng.random().bytes(&payload);

    std.debug.print("# zig-frame-protocol bench: roundtrip 256B (ReleaseFast, MONOTONIC ns)\n", .{});

    // Warm-up — discarded.
    var w: usize = 0;
    while (w < warmup_iters) : (w += 1) {
        const wire_len = try fp.encode(&wire, &enc_scratch, 0x42, @intCast(w), 0xCAFE, &payload);
        const frame = try fp.decode(wire[0..wire_len], &dec_scratch);
        std.mem.doNotOptimizeAway(frame.payload.len);
    }

    const t0 = nanos();
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const wire_len = try fp.encode(&wire, &enc_scratch, 0x42, @intCast(i), 0xCAFE, &payload);
        const frame = try fp.decode(wire[0..wire_len], &dec_scratch);
        std.mem.doNotOptimizeAway(frame.payload.len);
    }
    const total_ns = nanos() - t0;

    const ns_per_op = total_ns / iters;
    // Packets/sec: 1e9 ns/s / ns_per_op.
    const pkts_per_sec: u64 = @intCast(@as(u128, std.time.ns_per_s) * @as(u128, iters) / @max(@as(u128, total_ns), 1));
    const total_bytes: u128 = @as(u128, payload_size) * @as(u128, iters);
    const mbps: u128 = (total_bytes * 1000) / @max(@as(u128, total_ns), 1);

    std.debug.print(
        "bench=roundtrip size=256B bytes={d} op=ROUNDTRIP iters={d} total_ns={d} ns_per_op={d} MBps={d} pkts_per_sec={d}\n",
        .{ payload_size, iters, total_ns, ns_per_op, mbps, pkts_per_sec },
    );
}
