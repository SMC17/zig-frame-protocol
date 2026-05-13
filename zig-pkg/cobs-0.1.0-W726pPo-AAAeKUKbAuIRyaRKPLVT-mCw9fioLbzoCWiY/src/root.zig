//! Consistent Overhead Byte Stuffing (COBS).
//!
//! COBS is a framing algorithm that takes an arbitrary byte stream and produces
//! an output that contains no zero bytes, with a small bounded overhead. A
//! single 0x00 delimiter can then be used to mark frame boundaries in a stream.
//!
//! Reference: Cheshire & Baker, "Consistent Overhead Byte Stuffing" (SIGCOMM 1997).
//!
//! Worst-case overhead is `1 + ceil(len / 254)` bytes. For empty input the
//! encoding is a single byte (0x01). Decoded output never contains the frame
//! delimiter; encoded output never contains a zero byte.

const std = @import("std");

pub const Error = error{
    /// The destination buffer is smaller than `maxEncodedLength(src.len)`
    /// (for `encode`) or smaller than the decoded payload (for `decode`).
    BufferTooSmall,
    /// The source bytes are not a valid COBS frame (truncated or contains
    /// an embedded zero byte).
    InvalidEncoding,
};

/// Maximum number of bytes that `encode` may write for an input of `input_len`
/// bytes. Use this to size destination buffers.
///
/// Formula: `input_len + (input_len / 254) + 1`. The `/ 254` term accounts
/// for the overhead byte injected after each run of 254 non-zero bytes; the
/// trailing `+ 1` covers the leading overhead byte that COBS always emits.
pub fn maxEncodedLength(input_len: usize) usize {
    return input_len + (input_len / 254) + 1;
}

/// Encode `src` into `dst` using COBS. Returns the number of bytes written.
///
/// `dst` must be at least `maxEncodedLength(src.len)` bytes; otherwise the
/// function returns `error.BufferTooSmall`. The output never contains a zero
/// byte and is suitable for transmission followed by a 0x00 frame delimiter.
pub fn encode(src: []const u8, dst: []u8) Error!usize {
    const required = maxEncodedLength(src.len);
    if (dst.len < required) return Error.BufferTooSmall;

    var read_index: usize = 0;
    var write_index: usize = 1;
    var code_index: usize = 0;
    var code: u8 = 1;

    while (read_index < src.len) : (read_index += 1) {
        if (src[read_index] == 0) {
            dst[code_index] = code;
            code_index = write_index;
            write_index += 1;
            code = 1;
        } else {
            dst[write_index] = src[read_index];
            write_index += 1;
            code += 1;
            if (code == 0xFF) {
                dst[code_index] = code;
                code_index = write_index;
                write_index += 1;
                code = 1;
            }
        }
    }
    dst[code_index] = code;
    return write_index;
}

/// Decode a COBS-encoded frame from `src` into `dst`. Returns the number of
/// payload bytes written.
///
/// Returns `error.InvalidEncoding` if `src` is truncated or otherwise not a
/// well-formed COBS frame, and `error.BufferTooSmall` if `dst` cannot hold
/// the decoded payload.
pub fn decode(src: []const u8, dst: []u8) Error!usize {
    if (src.len == 0) return 0;

    var read_index: usize = 0;
    var write_index: usize = 0;

    while (read_index < src.len) {
        const code = src[read_index];
        if (code == 0) return Error.InvalidEncoding;
        read_index += 1;

        var i: u8 = 1;
        while (i < code) : (i += 1) {
            if (read_index >= src.len) return Error.InvalidEncoding;
            if (write_index >= dst.len) return Error.BufferTooSmall;
            dst[write_index] = src[read_index];
            write_index += 1;
            read_index += 1;
        }

        if (code < 0xFF and read_index < src.len) {
            if (write_index >= dst.len) return Error.BufferTooSmall;
            dst[write_index] = 0;
            write_index += 1;
        }
    }
    return write_index;
}

// ---- tests ----

const testing = std.testing;

test "maxEncodedLength bounds" {
    try testing.expectEqual(@as(usize, 1), maxEncodedLength(0));
    try testing.expectEqual(@as(usize, 2), maxEncodedLength(1));
    try testing.expectEqual(@as(usize, 256), maxEncodedLength(254));
    try testing.expectEqual(@as(usize, 257), maxEncodedLength(255));
    try testing.expectEqual(@as(usize, 511), maxEncodedLength(508));
}

test "encode empty input" {
    var out: [4]u8 = undefined;
    const n = try encode(&.{}, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u8, 0x01), out[0]);
}

test "encode single zero byte" {
    const src = [_]u8{0};
    var out: [4]u8 = undefined;
    const n = try encode(&src, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x01 }, out[0..n]);
}

test "encode single non-zero byte" {
    const src = [_]u8{0x42};
    var out: [4]u8 = undefined;
    const n = try encode(&src, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x42 }, out[0..n]);
}

test "encode rejects undersized destination" {
    const src = [_]u8{ 1, 2, 3 };
    var out: [3]u8 = undefined;
    try testing.expectError(Error.BufferTooSmall, encode(&src, &out));
}

test "encode 254 non-zero bytes triggers overhead injection" {
    var src: [254]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast((i % 254) + 1);
    var out: [256]u8 = undefined;
    const n = try encode(&src, &out);
    try testing.expectEqual(@as(usize, 256), n);
    try testing.expectEqual(@as(u8, 0xFF), out[0]);
    try testing.expectEqual(@as(u8, 0x01), out[255]);
}

test "encode at 255-byte boundary (overhead byte injected)" {
    var src: [255]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast((i % 254) + 1);
    const required = maxEncodedLength(src.len);
    try testing.expectEqual(@as(usize, 257), required);
    var out: [257]u8 = undefined;
    const n = try encode(&src, &out);
    try testing.expectEqual(@as(usize, 257), n);
    try testing.expectEqual(@as(u8, 0xFF), out[0]);
}

test "encode output contains no zero bytes" {
    var src: [512]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(0xC0B5);
    rng.random().bytes(&src);
    var out: [1024]u8 = undefined;
    const n = try encode(&src, &out);
    for (out[0..n]) |b| try testing.expect(b != 0);
}

test "decode rejects zero byte inside frame" {
    const bad = [_]u8{ 0x02, 0x41, 0x00, 0x01 };
    var out: [16]u8 = undefined;
    try testing.expectError(Error.InvalidEncoding, decode(&bad, &out));
}

test "decode rejects truncated frame" {
    const bad = [_]u8{ 0x05, 0x41, 0x42 };
    var out: [16]u8 = undefined;
    try testing.expectError(Error.InvalidEncoding, decode(&bad, &out));
}

test "decode rejects undersized destination" {
    const enc = [_]u8{ 0x03, 0x41, 0x42 };
    var out: [1]u8 = undefined;
    try testing.expectError(Error.BufferTooSmall, decode(&enc, &out));
}

test "roundtrip: ascii string with embedded zeros" {
    const src = "Carrier\x00Sovereign\x00AI";
    var enc: [maxEncodedLength(src.len)]u8 = undefined;
    var dec: [src.len]u8 = undefined;

    const enc_len = try encode(src, &enc);
    const dec_len = try decode(enc[0..enc_len], &dec);
    try testing.expectEqualStrings(src, dec[0..dec_len]);
}

test "roundtrip: all zeros" {
    const src = [_]u8{0} ** 32;
    var enc: [maxEncodedLength(src.len)]u8 = undefined;
    var dec: [src.len]u8 = undefined;

    const enc_len = try encode(&src, &enc);
    const dec_len = try decode(enc[0..enc_len], &dec);
    try testing.expectEqualSlices(u8, &src, dec[0..dec_len]);
}

test "roundtrip: all 0xFF" {
    const src = [_]u8{0xFF} ** 32;
    var enc: [maxEncodedLength(src.len)]u8 = undefined;
    var dec: [src.len]u8 = undefined;

    const enc_len = try encode(&src, &enc);
    const dec_len = try decode(enc[0..enc_len], &dec);
    try testing.expectEqualSlices(u8, &src, dec[0..dec_len]);
}

test "roundtrip: pseudo-random payloads across many lengths" {
    var rng = std.Random.DefaultPrng.init(0xCAFEBABE);
    var enc_buf: [4096]u8 = undefined;
    var dec_buf: [2048]u8 = undefined;
    var src_buf: [2048]u8 = undefined;

    var len: usize = 0;
    while (len <= 2048) : (len += if (len < 64) 1 else 37) {
        const src = src_buf[0..len];
        rng.random().bytes(src);

        const enc_len = try encode(src, &enc_buf);
        const dec_len = try decode(enc_buf[0..enc_len], &dec_buf);

        try testing.expectEqual(len, dec_len);
        try testing.expectEqualSlices(u8, src, dec_buf[0..dec_len]);
    }
}

test "encode size matches maxEncodedLength upper bound" {
    var rng = std.Random.DefaultPrng.init(0x5EED);
    var src_buf: [1024]u8 = undefined;
    var enc_buf: [2048]u8 = undefined;

    var len: usize = 0;
    while (len <= 1024) : (len += 13) {
        const src = src_buf[0..len];
        rng.random().bytes(src);
        const enc_len = try encode(src, &enc_buf);
        try testing.expect(enc_len <= maxEncodedLength(len));
    }
}
