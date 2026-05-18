//! coverage_driver — single-binary executable that exercises every public
//! function and every public error path in `src/root.zig`. The point isn't
//! to be a meaningful demo (the tests already are) — it's to be a plain
//! executable that `kcov` can run end-to-end, since the Zig 0.16 test
//! runner's debug-info layout currently confuses kcov on this nixpkgs build
//! (kcov is compiled without libbfd-dev; see zig-cobs CHANGELOG for the
//! full toolchain rationale).
//!
//! Three groups:
//!   1. Happy-path round-trips across the size matrix (0, 1, mid, large).
//!   2. Error-path coverage — every variant in `Error`.
//!   3. Length-formula helpers (packetLen, maxEncodedLen) on edge inputs.

const std = @import("std");
const fp = @import("frame_protocol");

pub fn main() !void {
    // --- 1. Happy-path round-trips ---
    try roundTrip(0x01, 0, 0, &[_]u8{});
    try roundTrip(0x02, 1, 1, &[_]u8{0x55});
    try roundTrip(0x03, 42, 1_700_000_000, &[_]u8{ 0x01, 0x02, 0x03 });
    try roundTrip(0xAB, 0xDEADBEEF, 1_234_567_890_123, &([_]u8{0xCC} ** 100));
    try roundTrip(0xFF, std.math.maxInt(u32), std.math.maxInt(u64), &([_]u8{0x42} ** 500));

    // Deterministic-pseudo-random payloads to exercise the CRC + COBS path
    // on a range of size classes.
    var prng = std.Random.DefaultPrng.init(0xFEEDFACE);
    const r = prng.random();
    inline for (.{ 1, 8, 64, 200, 254, 255, 256 }) |n| {
        var buf: [n]u8 = undefined;
        r.bytes(&buf);
        try roundTrip(0x10, n, n * 1000, &buf);
    }

    // --- 2. Error paths ---
    // PayloadTooLarge: buildPacket called with payload > max_payload_len.
    {
        var enc_out: [4096]u8 = undefined;
        const huge = [_]u8{0} ** 2048;
        try expectErr(fp.Error.PayloadTooLarge, fp.buildPacket(&enc_out, 0x01, 0, 0, &huge));
    }
    // BufferTooSmall: buildPacket with undersized out buffer.
    {
        var enc_out: [4]u8 = undefined;
        const small = [_]u8{0x01};
        try expectErr(fp.Error.BufferTooSmall, fp.buildPacket(&enc_out, 0x01, 0, 0, &small));
    }
    // BufferTooSmall on encodePacket (COBS encode into undersized buffer).
    {
        var packet: [128]u8 = undefined;
        const pkt_len = try fp.buildPacket(&packet, 0x01, 1, 1, &[_]u8{ 0x01, 0x02, 0x03 });
        var enc_out: [4]u8 = undefined;
        try expectErr(fp.Error.BufferTooSmall, fp.encodePacket(&enc_out, packet[0..pkt_len]));
    }
    // Truncated: decode of empty wire.
    {
        var scratch: [256]u8 = undefined;
        try expectErr(fp.Error.Truncated, fp.decode(&[_]u8{}, &scratch));
    }
    // Truncated: parsePacket on too-short packet.
    {
        try expectErr(fp.Error.Truncated, fp.parsePacket(&[_]u8{ 0x01, 0x02, 0x03 }));
    }
    // UnsupportedVersion: parsePacket on a packet with wrong version byte.
    {
        var pkt: [128]u8 = undefined;
        const n = try fp.buildPacket(&pkt, 0x01, 0, 0, &[_]u8{0x01});
        pkt[0] = 0xFF; // overwrite the version
        try expectErr(fp.Error.UnsupportedVersion, fp.parsePacket(pkt[0..n]));
    }
    // ChecksumMismatch: corrupt a byte in the packet body before parsing.
    {
        var pkt: [128]u8 = undefined;
        const n = try fp.buildPacket(&pkt, 0x01, 0, 0, &[_]u8{ 0x01, 0x02, 0x03 });
        pkt[16] ^= 0xFF; // flip a payload byte → CRC will fail
        try expectErr(fp.Error.ChecksumMismatch, fp.parsePacket(pkt[0..n]));
    }
    // InvalidEncoding: decode of bytes containing an in-frame zero.
    {
        var scratch: [256]u8 = undefined;
        const bad = [_]u8{ 0x02, 0x01, 0x00, 0x05 };
        try expectErr(fp.Error.InvalidEncoding, fp.decode(&bad, &scratch));
    }

    // --- 3. Length-formula helpers ---
    _ = fp.packetLen(0);
    _ = fp.packetLen(1);
    _ = fp.packetLen(255);
    _ = fp.packetLen(1024);
    _ = fp.maxEncodedLen(0);
    _ = fp.maxEncodedLen(1);
    _ = fp.maxEncodedLen(253);
    _ = fp.maxEncodedLen(254);
    _ = fp.maxEncodedLen(255);
    _ = fp.maxEncodedLen(1024);
}

fn roundTrip(kind: u8, seq: u32, ts_ms: u64, payload: []const u8) !void {
    var wire: [8192]u8 = undefined;
    var scratch: [8192]u8 = undefined;
    const wire_len = try fp.encode(&wire, &scratch, kind, seq, ts_ms, payload);
    const frame = try fp.decode(wire[0..wire_len], &scratch);
    if (frame.kind != kind) return error.KindMismatch;
    if (frame.sequence != seq) return error.SeqMismatch;
    if (frame.payload.len != payload.len) return error.PayloadLenMismatch;
    if (payload.len > 0 and !std.mem.eql(u8, frame.payload, payload)) return error.PayloadBytesMismatch;
}

fn expectErr(expected: fp.Error, actual: anytype) !void {
    if (actual) |_| {
        return error.ExpectedError;
    } else |err| {
        if (err != expected) return error.WrongError;
    }
}
