//! Encode-pipeline benchmark for zig-frame-protocol.
//!
//! Measures the *full* encode path — `fp.encode` does build (header + payload
//! + CRC32) followed by COBS framing plus delimiter — at three payload sizes
//! (16 B / 256 B / 1 KiB). Numbers reflect the throughput callers actually
//! see when serialising sensor frames; they are *not* just COBS speed.
//!
//! Timing strategy: `std.time.Timer` and `std.time.nanoTimestamp` were removed
//! in Zig 0.16's stdlib reshuffle. We call
//! `std.os.linux.clock_gettime(.MONOTONIC, &ts)` directly — same pattern Zig
//! 0.16 itself uses internally (see std/os/linux.zig). Single VDSO call on
//! x86_64 Linux, nanosecond resolution.

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
    var scratch: [fp.packetLen(max_payload)]u8 = undefined;
    var wire: [fp.maxEncodedLen(max_payload)]u8 = undefined;

    var rng = std.Random.DefaultPrng.init(0xF7A_E1C0_DE);
    rng.random().bytes(&payload_buf);

    std.debug.print("# zig-frame-protocol bench: encode (ReleaseFast, MONOTONIC ns)\n", .{});

    for (sizes) |s| {
        const payload = payload_buf[0..s.bytes];

        // Warm-up — discarded.
        var w: usize = 0;
        while (w < warmup_iters) : (w += 1) {
            const n = try fp.encode(&wire, &scratch, 0x42, @intCast(w), 0xCAFE, payload);
            std.mem.doNotOptimizeAway(n);
        }

        const t0 = nanos();
        var i: usize = 0;
        while (i < s.iters) : (i += 1) {
            const n = try fp.encode(&wire, &scratch, 0x42, @intCast(i), 0xCAFE, payload);
            std.mem.doNotOptimizeAway(n);
        }
        const total_ns = nanos() - t0;

        const ns_per_op = total_ns / s.iters;
        // Throughput reports *payload* bytes/s. The full wire output is
        // larger by the 20-byte header+CRC and ~0.4% COBS overhead.
        const total_bytes: u128 = @as(u128, s.bytes) * @as(u128, s.iters);
        const mbps: u128 = (total_bytes * 1000) / @max(@as(u128, total_ns), 1);

        std.debug.print(
            "bench=encode size={s} bytes={d} op=ENCODE iters={d} total_ns={d} ns_per_op={d} MBps={d}\n",
            .{ s.label, s.bytes, s.iters, total_ns, ns_per_op, mbps },
        );
    }
}
