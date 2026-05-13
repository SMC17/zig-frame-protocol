//! Adversarial fuzz / property tests for zig-frame-protocol.
//!
//! These tests close the "no fuzz/property testing yet" gap by exercising:
//!   1. Full-roundtrip property (10k random frames).
//!   2. Version-byte rejection for every plausible bad version.
//!   3. CRC single-bit corruption coverage across canonical frames.
//!   4. Truncation robustness for every wire prefix.
//!   5. Random-bytes-never-panic across 100k random wires.
//!   6. Payload-length-field tampering.
//!
//! All suites must never panic on adversarial input.

const std = @import("std");
const fp = @import("frame_protocol");
const testing = std.testing;

test "fuzz: 10k full-roundtrip random frames" {
    var rng = std.Random.DefaultPrng.init(0xA5A5_5A5A_DEAD_BEEF);
    var rand = rng.random();

    var scratch_buf: [fp.packetLen(fp.max_payload_len)]u8 = undefined;
    var wire_buf: [fp.maxEncodedLen(fp.max_payload_len)]u8 = undefined;
    var dec_buf: [fp.maxEncodedLen(fp.max_payload_len)]u8 = undefined;
    var payload_buf: [fp.max_payload_len]u8 = undefined;

    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const payload_len = rand.intRangeAtMost(usize, 0, fp.max_payload_len);
        const payload = payload_buf[0..payload_len];
        rand.bytes(payload);

        const kind: u8 = rand.int(u8);
        const sequence: u32 = rand.int(u32);
        const node_ms: u64 = rand.int(u64);

        const wire_len = try fp.encode(
            &wire_buf,
            &scratch_buf,
            kind,
            sequence,
            node_ms,
            payload,
        );
        const frame = try fp.decode(wire_buf[0..wire_len], &dec_buf);

        try testing.expectEqual(kind, frame.kind);
        try testing.expectEqual(sequence, frame.sequence);
        try testing.expectEqual(node_ms, frame.node_ms);
        try testing.expectEqualSlices(u8, payload, frame.payload);
    }
}

test "fuzz: version rejection across bad versions" {
    const bad_versions = [_]u8{ 0, 2, 3, 5, 100, 200, 255 };
    const payload = "version-rejection-test";

    var scratch_buf: [fp.packetLen(payload.len)]u8 = undefined;
    var wire_buf: [fp.maxEncodedLen(payload.len)]u8 = undefined;
    var dec_buf: [fp.maxEncodedLen(payload.len)]u8 = undefined;
    const cobs = @import("cobs");

    for (bad_versions) |bad_version| {
        // 1) Packet-level: build a valid packet, flip the version byte,
        // recompute CRC so the version check (which runs before checksum)
        // is exercised directly.
        var packet: [fp.packetLen(payload.len)]u8 = undefined;
        _ = try fp.buildPacket(&packet, 0x11, 0x2233_4455, 0x6677_8899_AABB_CCDD, payload);
        packet[0] = bad_version;
        const crc_offset = packet.len - fp.crc_len;
        const checksum = std.hash.Crc32.hash(packet[0..crc_offset]);
        std.mem.writeInt(u32, packet[crc_offset..][0..4], checksum, .little);

        try testing.expectError(fp.Error.UnsupportedVersion, fp.parsePacket(&packet));

        // 2) Wire-level: build a valid frame, decode the COBS layer back to
        // a packet, flip the version byte, recompute CRC, re-encode with
        // COBS, decode through the public API. Must error, never panic.
        const wire_len = try fp.encode(&wire_buf, &scratch_buf, 0x11, 0, 0, payload);
        var enc = wire_buf[0..wire_len];
        if (enc[enc.len - 1] == fp.delimiter) enc = enc[0 .. enc.len - 1];
        var pkt_scratch: [fp.maxEncodedLen(payload.len)]u8 = undefined;
        const pkt_len = try cobs.decode(enc, &pkt_scratch);
        pkt_scratch[0] = bad_version;
        const wire_crc_offset = pkt_len - fp.crc_len;
        const wire_checksum = std.hash.Crc32.hash(pkt_scratch[0..wire_crc_offset]);
        std.mem.writeInt(u32, pkt_scratch[wire_crc_offset..][0..4], wire_checksum, .little);
        var rewire: [fp.maxEncodedLen(payload.len)]u8 = undefined;
        const rewire_len = try fp.encodePacket(&rewire, pkt_scratch[0..pkt_len]);
        try testing.expectError(
            fp.Error.UnsupportedVersion,
            fp.decode(rewire[0..rewire_len], &dec_buf),
        );
    }
}

// Helper: number of bits in the COBS overhead-byte position (first byte of
// the encoded packet), so the CRC bit-flip test can skip them. Flipping the
// COBS overhead/delimiter region causes legitimate InvalidEncoding /
// Truncated errors that are not CRC's job to catch.
const cobs_overhead_skip_bits: usize = 8;

test "fuzz: CRC single-bit corruption across canonical frames" {
    // Five canonical valid frames covering small / medium / max payload.
    const sizes = [_]usize{ 0, 1, 32, 256, fp.max_payload_len };

    var scratch_buf: [fp.packetLen(fp.max_payload_len)]u8 = undefined;
    var wire_buf: [fp.maxEncodedLen(fp.max_payload_len)]u8 = undefined;
    var dec_buf: [fp.maxEncodedLen(fp.max_payload_len)]u8 = undefined;
    var payload_buf: [fp.max_payload_len]u8 = undefined;
    var mutated_buf: [fp.maxEncodedLen(fp.max_payload_len)]u8 = undefined;

    var rng = std.Random.DefaultPrng.init(0xDEAD_C0DE_FEED_FACE);
    var rand = rng.random();

    var total_flips: usize = 0;
    var caught_by_crc: usize = 0;
    var caught_by_other: usize = 0;
    var caught_by_diff_frame: usize = 0;

    for (sizes) |size| {
        const payload = payload_buf[0..size];
        rand.bytes(payload);

        const kind: u8 = 0x5A;
        const sequence: u32 = 0xCAFE_BABE;
        const node_ms: u64 = 0x0123_4567_89AB_CDEF;

        const wire_len = try fp.encode(&wire_buf, &scratch_buf, kind, sequence, node_ms, payload);
        const wire = wire_buf[0..wire_len];

        // Establish baseline: decode the unmodified wire and stash the
        // original frame fields for comparison.
        const original = try fp.decode(wire, &dec_buf);
        const orig_kind = original.kind;
        const orig_seq = original.sequence;
        const orig_node = original.node_ms;

        // For every bit in the wire EXCEPT the trailing 0x00 delimiter and
        // the COBS overhead byte at index 0 (flipping those causes legit
        // framing errors, not CRC's responsibility).
        var byte_idx: usize = 1; // skip COBS overhead byte at index 0
        while (byte_idx < wire_len - 1) : (byte_idx += 1) {
            var bit: u3 = 0;
            while (true) : (bit +%= 1) {
                @memcpy(mutated_buf[0..wire_len], wire);
                mutated_buf[byte_idx] ^= (@as(u8, 1) << bit);

                total_flips += 1;

                const result = fp.decode(mutated_buf[0..wire_len], &dec_buf);
                if (result) |frame| {
                    // No error returned — frame must differ from original
                    // OR payload must differ. Never the exact same frame.
                    const same_fields = frame.kind == orig_kind and
                        frame.sequence == orig_seq and
                        frame.node_ms == orig_node;
                    const same_payload = std.mem.eql(u8, frame.payload, payload);
                    try testing.expect(!(same_fields and same_payload));
                    caught_by_diff_frame += 1;
                } else |err| switch (err) {
                    fp.Error.ChecksumMismatch => caught_by_crc += 1,
                    fp.Error.UnsupportedVersion,
                    fp.Error.PayloadLengthMismatch,
                    fp.Error.Truncated,
                    fp.Error.InvalidEncoding,
                    fp.Error.BufferTooSmall,
                    fp.Error.PayloadTooLarge,
                    => caught_by_other += 1,
                }

                if (bit == 7) break;
            }
        }
    }

    // Sanity: we executed a non-trivial number of flips.
    try testing.expect(total_flips > 1000);

    // CRC must catch a non-trivial share of payload-region flips. The byte
    // count of header+payload+crc spans most of the wire, so we expect CRC
    // to dominate the "caught" bucket. We assert a conservative lower bound.
    const total_caught = caught_by_crc + caught_by_other + caught_by_diff_frame;
    try testing.expectEqual(total_flips, total_caught);
    try testing.expect(caught_by_crc * 2 >= total_flips); // > 50%

    std.debug.print(
        "  [crc fuzz] flips={d}  crc-caught={d}  other-error={d}  diff-frame={d}\n",
        .{ total_flips, caught_by_crc, caught_by_other, caught_by_diff_frame },
    );
}

test "fuzz: truncation robustness across every prefix" {
    const sizes = [_]usize{ 0, 1, 16, 64, 256, fp.max_payload_len };

    var scratch_buf: [fp.packetLen(fp.max_payload_len)]u8 = undefined;
    var wire_buf: [fp.maxEncodedLen(fp.max_payload_len)]u8 = undefined;
    var dec_buf: [fp.maxEncodedLen(fp.max_payload_len)]u8 = undefined;
    var payload_buf: [fp.max_payload_len]u8 = undefined;

    var rng = std.Random.DefaultPrng.init(0xBADD_CAFE_F00D_BEEF);
    var rand = rng.random();

    for (sizes) |size| {
        const payload = payload_buf[0..size];
        rand.bytes(payload);

        const wire_len = try fp.encode(
            &wire_buf,
            &scratch_buf,
            0x77,
            0x1234_5678,
            0xAABB_CCDD_EEFF_0011,
            payload,
        );

        // For every prefix length n in [0, wire_len - 1): truncation must
        // error, never panic. We stop at wire_len - 1 because n == wire_len - 1
        // strips only the trailing 0x00 delimiter, which the protocol
        // explicitly accepts (see the "decode without trailing delimiter
        // still works" test). Any shorter prefix is a true truncation.
        var n: usize = 0;
        const last: usize = if (wire_len == 0) 0 else wire_len - 1;
        while (n < last) : (n += 1) {
            if (fp.decode(wire_buf[0..n], &dec_buf)) |_| {
                // Any successful decode from a true-truncated prefix
                // violates the truncation contract.
                try testing.expect(false);
            } else |_| {
                // Errored — expected (Truncated, InvalidEncoding,
                // PayloadLengthMismatch, ChecksumMismatch all acceptable).
            }
        }
    }
}

test "fuzz: 100k random wires never panic" {
    var rng = std.Random.DefaultPrng.init(0xFEED_FACE_CAFE_BABE);
    var rand = rng.random();

    var wire_buf: [1200]u8 = undefined;
    var dec_buf: [4096]u8 = undefined;

    var i: usize = 0;
    var ok_count: usize = 0;
    var err_count: usize = 0;
    while (i < 100_000) : (i += 1) {
        const len = rand.intRangeAtMost(usize, 0, 1200);
        rand.bytes(wire_buf[0..len]);

        const result = fp.decode(wire_buf[0..len], &dec_buf);
        if (result) |_| {
            ok_count += 1;
        } else |_| {
            err_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 100_000), ok_count + err_count);
}

test "fuzz: payload-length-field tampering" {
    const payload = "tamper-the-length-field";

    var scratch_buf: [fp.packetLen(payload.len)]u8 = undefined;
    var wire_buf: [fp.maxEncodedLen(payload.len)]u8 = undefined;
    var dec_buf: [fp.maxEncodedLen(payload.len)]u8 = undefined;

    // Drive the test through the packet-level API (parsePacket) where the
    // length field can be tampered with directly. The wire-level API would
    // re-CRC after COBS, so we'd get ChecksumMismatch trivially — both
    // outcomes are acceptable per spec.
    const tampered_values = [_]u16{
        0,
        @intCast(payload.len + 1),
        @intCast(payload.len - 1),
        0xFFFF,
        100,
        1024,
    };

    for (tampered_values) |bogus_len| {
        var packet: [fp.packetLen(payload.len)]u8 = undefined;
        _ = try fp.buildPacket(&packet, 0x33, 0xAAAA_BBBB, 0xCCCC_DDDD_EEEE_FFFF, payload);

        // Tamper the length field. Don't recompute CRC — both
        // PayloadLengthMismatch and ChecksumMismatch are acceptable
        // outcomes.
        std.mem.writeInt(u16, packet[14..16], bogus_len, .little);

        const result = fp.parsePacket(&packet);
        if (result) |_| {
            // If the tampered length still parsed (e.g. bogus_len == real
            // length after coincidence), CRC must catch it elsewhere — but
            // since we didn't change anything else, this is only possible
            // when bogus_len equals payload.len, which we explicitly avoid.
            try testing.expect(bogus_len == payload.len);
        } else |err| {
            try testing.expect(err == fp.Error.PayloadLengthMismatch or
                err == fp.Error.ChecksumMismatch or
                err == fp.Error.Truncated);
        }
    }

    // Also exercise the wire path: tamper the decoded packet's length field
    // and re-encode through COBS, then decode. CRC should catch this.
    {
        const wire_len = try fp.encode(&wire_buf, &scratch_buf, 0x33, 1, 2, payload);
        var pkt_scratch: [fp.maxEncodedLen(payload.len)]u8 = undefined;
        // Strip optional delimiter.
        var enc = wire_buf[0..wire_len];
        if (enc[enc.len - 1] == fp.delimiter) enc = enc[0 .. enc.len - 1];
        const cobs = @import("cobs");
        const pkt_len = try cobs.decode(enc, &pkt_scratch);

        // Tamper length field.
        std.mem.writeInt(u16, pkt_scratch[14..16], @intCast(payload.len + 5), .little);

        const result = fp.parsePacket(pkt_scratch[0..pkt_len]);
        try testing.expect(result == fp.Error.PayloadLengthMismatch or
            result == fp.Error.ChecksumMismatch);

        // Re-encode the tampered packet and run through the full decode path
        // for completeness.
        var rewire: [fp.maxEncodedLen(payload.len)]u8 = undefined;
        const rewire_len = try fp.encodePacket(&rewire, pkt_scratch[0..pkt_len]);
        const wire_result = fp.decode(rewire[0..rewire_len], &dec_buf);
        try testing.expect(wire_result == fp.Error.PayloadLengthMismatch or
            wire_result == fp.Error.ChecksumMismatch);
    }
}
