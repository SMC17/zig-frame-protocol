//! Versioned binary frame protocol for byte streams.
//!
//! Each frame on the wire has this layout:
//!
//! ```text
//!  offset  size  field
//!  ------  ----  -----------------------------------------
//!     0     1    version           (currently always 1)
//!     1     1    kind              (caller-defined, 0–255)
//!     2     4    sequence          (u32 little-endian)
//!     6     8    node_ms           (u64 little-endian)
//!    14     2    payload_len       (u16 little-endian)
//!    16     N    payload           (N = payload_len bytes)
//!  16+N     4    crc32             (IEEE 802.3, little-endian)
//! ```
//!
//! The whole packet (20 + N bytes) is then framed with COBS and terminated
//! by a single `0x00` delimiter, producing the wire representation. COBS
//! guarantees the encoded bytes contain no zeros, so the delimiter is
//! unambiguous.
//!
//! The `kind` byte is intentionally not an enum — callers define their own
//! kind taxonomy. The protocol is opinionated about transport (versioned,
//! sequenced, timestamped, integrity-checked, self-delimited) and unopinionated
//! about payload semantics.
//!
//! All functions operate on caller-provided buffers (no allocation). The
//! maximum payload size is bounded by `max_payload_len`; callers requiring
//! larger frames should consume the lower-level `buildPacket` /
//! `encodePacket` / `parsePacket` primitives directly.

const std = @import("std");
const cobs = @import("cobs");

pub const version: u8 = 1;
pub const header_len: usize = 16;
pub const crc_len: usize = 4;
pub const overhead_len: usize = header_len + crc_len; // 20
pub const max_payload_len: usize = 1024;
pub const delimiter: u8 = 0;

pub const Error = error{
    /// Payload exceeds `max_payload_len`.
    PayloadTooLarge,
    /// Destination buffer is smaller than the worst-case encoded length.
    BufferTooSmall,
    /// Source frame is truncated or otherwise too short to be valid.
    Truncated,
    /// Source frame is not well-formed COBS data.
    InvalidEncoding,
    /// Frame version byte does not match this library's `version` constant.
    UnsupportedVersion,
    /// Payload length field disagrees with the actual decoded packet length.
    PayloadLengthMismatch,
    /// CRC32 trailer does not match the computed checksum over the header
    /// and payload bytes.
    ChecksumMismatch,
};

pub const Frame = struct {
    kind: u8,
    sequence: u32,
    node_ms: u64,
    payload: []const u8,
};

/// Exact size of the inner packet (header + payload + CRC) before COBS framing.
pub fn packetLen(payload_len: usize) usize {
    return header_len + payload_len + crc_len;
}

/// Worst-case size of a fully-encoded wire frame (COBS-encoded packet plus
/// the trailing `0x00` delimiter) for the given payload length.
pub fn maxEncodedLen(payload_len: usize) usize {
    return cobs.maxEncodedLength(packetLen(payload_len)) + 1;
}

/// Build a packet (header + payload + CRC) in `out`. Returns the number of
/// bytes written, which is always `packetLen(payload.len)`.
///
/// `out.len` must be at least `packetLen(payload.len)`; otherwise returns
/// `error.BufferTooSmall`.
pub fn buildPacket(
    out: []u8,
    kind: u8,
    sequence: u32,
    node_ms: u64,
    payload: []const u8,
) Error!usize {
    if (payload.len > max_payload_len) return Error.PayloadTooLarge;
    const need = packetLen(payload.len);
    if (out.len < need) return Error.BufferTooSmall;

    out[0] = version;
    out[1] = kind;
    std.mem.writeInt(u32, out[2..6], sequence, .little);
    std.mem.writeInt(u64, out[6..14], node_ms, .little);
    std.mem.writeInt(u16, out[14..16], @intCast(payload.len), .little);
    @memcpy(out[header_len..][0..payload.len], payload);

    const crc_offset = header_len + payload.len;
    const checksum = std.hash.Crc32.hash(out[0..crc_offset]);
    std.mem.writeInt(u32, out[crc_offset..][0..4], checksum, .little);

    return need;
}

/// Encode an already-built packet via COBS and append the `0x00` delimiter.
/// Returns the total wire-byte count (encoded packet plus delimiter).
///
/// `out.len` must be at least `cobs.maxEncodedLength(packet.len) + 1`;
/// otherwise returns `error.BufferTooSmall`.
pub fn encodePacket(out: []u8, packet: []const u8) Error!usize {
    const need = cobs.maxEncodedLength(packet.len) + 1;
    if (out.len < need) return Error.BufferTooSmall;

    const encoded_len = cobs.encode(packet, out) catch |err| switch (err) {
        cobs.Error.BufferTooSmall => return Error.BufferTooSmall,
        cobs.Error.InvalidEncoding => unreachable, // encode never returns this
    };
    out[encoded_len] = delimiter;
    return encoded_len + 1;
}

/// Convenience: build a packet from fields and immediately COBS-encode it.
/// `scratch` is used as the packet buffer and must be at least
/// `packetLen(payload.len)` bytes; `out` must be at least
/// `maxEncodedLen(payload.len)` bytes.
pub fn encode(
    out: []u8,
    scratch: []u8,
    kind: u8,
    sequence: u32,
    node_ms: u64,
    payload: []const u8,
) Error!usize {
    const packet_len = try buildPacket(scratch, kind, sequence, node_ms, payload);
    return encodePacket(out, scratch[0..packet_len]);
}

/// Parse a fully-decoded packet (header + payload + CRC, no COBS) into a
/// `Frame`. The returned `Frame.payload` is a sub-slice of `packet`; `packet`
/// must outlive the returned `Frame`.
pub fn parsePacket(packet: []const u8) Error!Frame {
    if (packet.len < header_len + crc_len) return Error.Truncated;
    if (packet[0] != version) return Error.UnsupportedVersion;

    const payload_len: usize = std.mem.readInt(u16, packet[14..16], .little);
    if (packet.len != header_len + payload_len + crc_len) {
        return Error.PayloadLengthMismatch;
    }

    const crc_offset = header_len + payload_len;
    const expected = std.mem.readInt(u32, packet[crc_offset..][0..4], .little);
    const actual = std.hash.Crc32.hash(packet[0..crc_offset]);
    if (expected != actual) return Error.ChecksumMismatch;

    return .{
        .kind = packet[1],
        .sequence = std.mem.readInt(u32, packet[2..6], .little),
        .node_ms = std.mem.readInt(u64, packet[6..14], .little),
        .payload = packet[header_len..crc_offset],
    };
}

/// Decode a wire frame: strip the optional trailing `0x00` delimiter, COBS-
/// decode into `scratch`, and parse the result. `scratch` must be large
/// enough to hold the decoded packet (`wire.len` is a safe upper bound).
///
/// The returned `Frame.payload` is a sub-slice of `scratch`; `scratch` must
/// outlive the returned `Frame`.
pub fn decode(wire: []const u8, scratch: []u8) Error!Frame {
    var encoded = wire;
    if (encoded.len > 0 and encoded[encoded.len - 1] == delimiter) {
        encoded = encoded[0 .. encoded.len - 1];
    }
    if (encoded.len == 0) return Error.Truncated;

    const packet_len = cobs.decode(encoded, scratch) catch |err| switch (err) {
        cobs.Error.BufferTooSmall => return Error.BufferTooSmall,
        cobs.Error.InvalidEncoding => return Error.InvalidEncoding,
    };
    return parsePacket(scratch[0..packet_len]);
}

// ---- tests ----

const testing = std.testing;

test "packetLen and maxEncodedLen" {
    try testing.expectEqual(@as(usize, 20), packetLen(0));
    try testing.expectEqual(@as(usize, 28), packetLen(8));
    try testing.expectEqual(@as(usize, 1044), packetLen(max_payload_len));
    try testing.expect(maxEncodedLen(0) >= 21);
    try testing.expect(maxEncodedLen(max_payload_len) >= packetLen(max_payload_len) + 1);
}

test "encode/decode roundtrip with empty payload" {
    var scratch: [packetLen(0)]u8 = undefined;
    var wire: [maxEncodedLen(0)]u8 = undefined;
    var dec_scratch: [maxEncodedLen(0)]u8 = undefined;

    const wire_len = try encode(&wire, &scratch, 7, 42, 0xDEAD_BEEF_CAFE_F00D, &.{});
    const frame = try decode(wire[0..wire_len], &dec_scratch);

    try testing.expectEqual(@as(u8, 7), frame.kind);
    try testing.expectEqual(@as(u32, 42), frame.sequence);
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF_CAFE_F00D), frame.node_ms);
    try testing.expectEqual(@as(usize, 0), frame.payload.len);
}

test "encode/decode roundtrip with ascii payload" {
    const payload = "hello\x00world\x00\x00bytes";
    var scratch: [packetLen(64)]u8 = undefined;
    var wire: [maxEncodedLen(64)]u8 = undefined;
    var dec_scratch: [maxEncodedLen(64)]u8 = undefined;

    const wire_len = try encode(&wire, &scratch, 1, 100, 0, payload);

    // Wire bytes contain no internal zeros except the trailing delimiter.
    for (wire[0 .. wire_len - 1]) |b| try testing.expect(b != 0);
    try testing.expectEqual(@as(u8, 0), wire[wire_len - 1]);

    const frame = try decode(wire[0..wire_len], &dec_scratch);
    try testing.expectEqual(@as(u8, 1), frame.kind);
    try testing.expectEqualStrings(payload, frame.payload);
}

test "encode/decode roundtrip at max_payload_len" {
    var payload: [max_payload_len]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(0xFADEBEEF);
    rng.random().bytes(&payload);

    var scratch: [packetLen(max_payload_len)]u8 = undefined;
    var wire: [maxEncodedLen(max_payload_len)]u8 = undefined;
    var dec_scratch: [maxEncodedLen(max_payload_len)]u8 = undefined;

    const wire_len = try encode(&wire, &scratch, 0xAA, 0xBBCC_DDEE, 0x1122_3344_5566_7788, &payload);
    const frame = try decode(wire[0..wire_len], &dec_scratch);

    try testing.expectEqual(@as(u8, 0xAA), frame.kind);
    try testing.expectEqual(@as(u32, 0xBBCC_DDEE), frame.sequence);
    try testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), frame.node_ms);
    try testing.expectEqualSlices(u8, &payload, frame.payload);
}

test "encode rejects oversized payload" {
    const too_big = [_]u8{0xAB} ** (max_payload_len + 1);
    var scratch: [4096]u8 = undefined;
    var wire: [8192]u8 = undefined;
    try testing.expectError(
        Error.PayloadTooLarge,
        encode(&wire, &scratch, 0, 0, 0, &too_big),
    );
}

test "encode rejects undersized scratch" {
    const payload = "ab";
    var scratch: [4]u8 = undefined;
    var wire: [64]u8 = undefined;
    try testing.expectError(
        Error.BufferTooSmall,
        encode(&wire, &scratch, 0, 0, 0, payload),
    );
}

test "encode rejects undersized output" {
    const payload = "ab";
    var scratch: [packetLen(2)]u8 = undefined;
    var wire: [4]u8 = undefined;
    try testing.expectError(
        Error.BufferTooSmall,
        encode(&wire, &scratch, 0, 0, 0, payload),
    );
}

test "decode rejects empty wire" {
    var dec_scratch: [64]u8 = undefined;
    try testing.expectError(Error.Truncated, decode(&.{}, &dec_scratch));
}

test "decode rejects lone delimiter" {
    var dec_scratch: [64]u8 = undefined;
    const wire = [_]u8{0};
    try testing.expectError(Error.Truncated, decode(&wire, &dec_scratch));
}

test "decode without trailing delimiter still works" {
    const payload = "abc";
    var scratch: [packetLen(64)]u8 = undefined;
    var wire: [maxEncodedLen(64)]u8 = undefined;
    var dec_scratch: [maxEncodedLen(64)]u8 = undefined;

    const wire_len = try encode(&wire, &scratch, 9, 1, 2, payload);
    // Strip trailing delimiter and decode again.
    const frame = try decode(wire[0 .. wire_len - 1], &dec_scratch);
    try testing.expectEqual(@as(u8, 9), frame.kind);
    try testing.expectEqualStrings(payload, frame.payload);
}

test "decode rejects unsupported version" {
    var packet: [packetLen(4)]u8 = undefined;
    _ = try buildPacket(&packet, 0, 0, 0, "data");
    packet[0] = version + 1;
    // Recompute CRC over corrupted packet so we exercise the version check
    // before the checksum check.
    const crc_offset = packet.len - crc_len;
    const checksum = std.hash.Crc32.hash(packet[0..crc_offset]);
    std.mem.writeInt(u32, packet[crc_offset..][0..4], checksum, .little);

    try testing.expectError(Error.UnsupportedVersion, parsePacket(&packet));
}

test "decode rejects CRC corruption" {
    const payload = "payload";
    var scratch: [packetLen(payload.len)]u8 = undefined;
    var wire: [maxEncodedLen(payload.len)]u8 = undefined;
    var dec_scratch: [maxEncodedLen(payload.len)]u8 = undefined;

    const wire_len = try encode(&wire, &scratch, 0, 0, 0, payload);

    // Decode to a packet, corrupt one byte, re-parse.
    const enc = wire[0 .. wire_len - 1];
    const packet_len_ = try cobs.decode(enc, &dec_scratch);
    dec_scratch[header_len + 2] ^= 0xFF; // flip a payload byte
    try testing.expectError(Error.ChecksumMismatch, parsePacket(dec_scratch[0..packet_len_]));
}

test "decode rejects payload length mismatch" {
    const payload = "payload";
    var packet: [packetLen(payload.len)]u8 = undefined;
    _ = try buildPacket(&packet, 0, 0, 0, payload);

    // Forge a payload_len that disagrees with the actual remaining bytes.
    std.mem.writeInt(u16, packet[14..16], @intCast(payload.len + 1), .little);

    try testing.expectError(Error.PayloadLengthMismatch, parsePacket(&packet));
}

test "wire format byte fixture" {
    // Verify the exact wire layout for a known frame so any silent format
    // change shows up immediately.
    var scratch: [packetLen(4)]u8 = undefined;
    const n = try buildPacket(&scratch, 0x42, 0x11223344, 0x0102030405060708, "data");
    try testing.expectEqual(@as(usize, 24), n);

    const expected_header = [_]u8{
        0x01, // version
        0x42, // kind
        0x44, 0x33, 0x22, 0x11, // sequence LE
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, // node_ms LE
        0x04, 0x00, // payload_len LE
        'd',  'a',
        't',  'a',
    };
    try testing.expectEqualSlices(u8, &expected_header, scratch[0..20]);
}

test "property-based roundtrip across payload lengths" {
    var rng = std.Random.DefaultPrng.init(0xC0DEFADE);
    var scratch_buf: [packetLen(max_payload_len)]u8 = undefined;
    var wire_buf: [maxEncodedLen(max_payload_len)]u8 = undefined;
    var dec_buf: [maxEncodedLen(max_payload_len)]u8 = undefined;
    var payload_buf: [max_payload_len]u8 = undefined;

    var len: usize = 0;
    while (len <= max_payload_len) : (len += if (len < 32) 1 else 73) {
        const payload = payload_buf[0..len];
        rng.random().bytes(payload);

        const wire_len = try encode(
            &wire_buf,
            &scratch_buf,
            @intCast(len & 0xFF),
            @intCast(len),
            @as(u64, len) *% 0x9E37_79B9,
            payload,
        );
        const frame = try decode(wire_buf[0..wire_len], &dec_buf);

        try testing.expectEqual(@as(u8, @intCast(len & 0xFF)), frame.kind);
        try testing.expectEqual(@as(u32, @intCast(len)), frame.sequence);
        try testing.expectEqual(@as(u64, len) *% 0x9E37_79B9, frame.node_ms);
        try testing.expectEqualSlices(u8, payload, frame.payload);
    }
}
