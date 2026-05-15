# zig-frame-protocol

[![CI](https://github.com/SMC17/zig-frame-protocol/actions/workflows/ci.yml/badge.svg)](https://github.com/SMC17/zig-frame-protocol/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/SMC17/zig-frame-protocol?display_name=tag&sort=semver)](https://github.com/SMC17/zig-frame-protocol/releases) [![License](https://img.shields.io/github/license/SMC17/zig-frame-protocol)](LICENSE)

A small, versioned binary frame protocol for byte streams. Each frame carries
a kind byte, a 32-bit sequence number, a 64-bit timestamp, a 16-bit payload
length, the payload itself, and a CRC32 trailer — then is COBS-framed and
delimited by a single `0x00` byte for unambiguous stream parsing.

Built on top of [`zig-cobs`][zig-cobs]. Zero allocation, no dependencies
beyond cobs, suitable for embedded targets and host-side stream processing.

[zig-cobs]: https://github.com/SMC17/zig-cobs

## Wire format

```text
 offset  size  field
 ------  ----  -----------------------------------------
    0     1    version           (currently always 1)
    1     1    kind              (caller-defined, 0–255)
    2     4    sequence          (u32 little-endian)
    6     8    node_ms           (u64 little-endian)
   14     2    payload_len       (u16 little-endian)
   16     N    payload           (N = payload_len bytes)
 16+N     4    crc32             (IEEE 802.3, little-endian)
```

The whole packet (`20 + N` bytes) is COBS-framed and terminated with `0x00`.
COBS guarantees the encoded bytes contain no zeros, so the delimiter is
unambiguous on the wire.

The `kind` byte is intentionally not an enum — callers define their own
taxonomy. The protocol is opinionated about transport (versioned, sequenced,
timestamped, integrity-checked, self-delimited) and unopinionated about
payload semantics.

## Status

`v0.1.0` — initial release. 21 unit tests cover roundtrip across payload
sizes 0–1024, all error paths (truncation, version mismatch, CRC corruption,
length mismatch, oversized payloads, undersized buffers), a fixed
byte-layout fixture so silent wire-format drift is impossible, and an
adversarial fuzz suite covering bit-flip robustness, prefix truncation, and
a 100k random-wire never-panic guarantee.

Minimum Zig version: `0.15.0`. Tested on Zig `0.16.0`.

CI covers Linux x86_64, Linux aarch64, and macOS arm64 (native runners), plus
cross-compile sanity for `aarch64-linux-gnu`, `aarch64-macos`,
`x86_64-linux-gnu`, and `x86_64-macos` from the x86_64 host.

## Install

Add to `build.zig.zon`:

```zig
.dependencies = .{
    .frame_protocol = .{
        .url = "https://github.com/SMC17/zig-frame-protocol/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

In `build.zig`:

```zig
const fp = b.dependency("frame_protocol", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("frame_protocol", fp.module("frame_protocol"));
```

## Quickstart

```zig
const std = @import("std");
const fp = @import("frame_protocol");

pub fn main() !void {
    const payload = "hello world";

    var scratch: [fp.packetLen(payload.len)]u8 = undefined;
    var wire: [fp.maxEncodedLen(payload.len)]u8 = undefined;

    const wire_len = try fp.encode(
        &wire,
        &scratch,
        0x42,              // kind (caller-defined)
        100,               // sequence
        1_715_000_000_000, // node_ms
        payload,
    );
    std.debug.print("wire: {} bytes\n", .{wire_len});

    // ... transmit wire[0..wire_len] ...

    var dec_scratch: [fp.maxEncodedLen(payload.len)]u8 = undefined;
    const frame = try fp.decode(wire[0..wire_len], &dec_scratch);

    std.debug.assert(frame.kind == 0x42);
    std.debug.assert(frame.sequence == 100);
    std.debug.assert(std.mem.eql(u8, payload, frame.payload));
}
```

## API

### Constants

```zig
pub const version: u8 = 1;
pub const header_len: usize = 16;
pub const crc_len: usize = 4;
pub const overhead_len: usize = 20;
pub const max_payload_len: usize = 1024;
pub const delimiter: u8 = 0;
```

### Sizing helpers

```zig
pub fn packetLen(payload_len: usize) usize;
pub fn maxEncodedLen(payload_len: usize) usize;
```

### High-level

```zig
pub fn encode(
    out: []u8,
    scratch: []u8,
    kind: u8,
    sequence: u32,
    node_ms: u64,
    payload: []const u8,
) Error!usize;

pub fn decode(wire: []const u8, scratch: []u8) Error!Frame;
```

### Low-level (no scratch coupling)

```zig
pub fn buildPacket(
    out: []u8,
    kind: u8,
    sequence: u32,
    node_ms: u64,
    payload: []const u8,
) Error!usize;

pub fn encodePacket(out: []u8, packet: []const u8) Error!usize;
pub fn parsePacket(packet: []const u8) Error!Frame;
```

### Types

```zig
pub const Frame = struct {
    kind: u8,
    sequence: u32,
    node_ms: u64,
    payload: []const u8,
};

pub const Error = error{
    PayloadTooLarge,
    BufferTooSmall,
    Truncated,
    InvalidEncoding,
    UnsupportedVersion,
    PayloadLengthMismatch,
    ChecksumMismatch,
};
```

## Design notes

**Why a separate library.** The frame protocol is independent of any single
application's `kind` taxonomy. By taking `kind` as a `u8` and leaving the
enum to the caller, the library composes naturally with any project's
message dictionary. Multiple projects depending on this library does **not**
require them to share kind values.

**Why COBS as a dependency.** Self-delimiting frames need an unambiguous
delimiter byte. COBS is the standard choice for "any byte stream, never
contains a 0, ~0.4% worst-case overhead." See `zig-cobs` for details.

**Why CRC32 and not stronger.** IEEE 802.3 CRC32 catches all 1–3 bit errors,
all odd-bit-count errors, and all burst errors up to 32 bits long, with a
miss rate of ~2.3 × 10⁻¹⁰ on random corruption. For embedded sensor links
or short-haul host streams this is sufficient. Authenticated cryptographic
integrity is out of scope — wrap this protocol with HMAC or AEAD at a
higher layer if you need it.

**Bounded payload size.** The encode convenience uses caller-provided
scratch, so the practical max payload is whatever the caller chooses to
allocate. The `max_payload_len = 1024` constant exists as a guard against
the u16 length field overflow (real max would be 65535) and is set
conservatively for embedded use. Larger payloads are supported by
constructing packets directly via `buildPacket` / `encodePacket` if you
prefer to manage the upper bound yourself.

## Tests

```sh
zig build test
```

21 tests covering:

- `packetLen` / `maxEncodedLen` size math
- Empty-payload roundtrip
- ASCII payload with embedded zeros (verifies COBS escaping works end-to-end)
- Maximum payload roundtrip
- Property-based roundtrip across all payload sizes 0–1024 with
  pseudo-random data
- Oversized-payload rejection
- Undersized-scratch and undersized-output rejection
- Empty wire and lone-delimiter rejection
- Decode without trailing delimiter (transport optionality)
- Unsupported-version rejection
- CRC-mismatch detection
- Payload-length-field-mismatch detection
- **Byte-fixture test** that pins the exact wire format — any future change
  to header layout will fail this test loudly.

Adversarial fuzz testing (`src/fuzz_test.zig`) now covers bit-flip
robustness, truncation, and random-wire never-panic guarantees:

- **10,000 randomized full roundtrips** across all four frame fields
- **Version rejection** at packet and wire level for `{0,2,3,5,100,200,255}`
- **CRC single-bit corruption** sweep over every bit of canonical frames
  (small / medium / max payload); reports CRC catch rate (~98% of payload-
  region flips in the current build)
- **Truncation robustness** across every wire prefix
- **100,000 random-byte wires** — `decode` must never panic
- **Payload-length-field tampering** — must return
  `PayloadLengthMismatch` or `ChecksumMismatch`, never panic

## Benchmarks

```sh
zig build bench
```

Three benchmarks ship under `bench/`:

- `bench_encode.zig` — full encode pipeline (header build + CRC32 + COBS
  framing) at 16 B / 256 B / 1 KiB payloads
- `bench_decode.zig` — full decode pipeline (COBS decode + header parse +
  CRC32 verify) at the same matrix
- `bench_roundtrip.zig` — end-to-end encode→decode at a 256 B payload, with
  packets-per-second reported

Each benchmark warms up for 1 000 iterations, then measures with enough
iterations (2 M for 16 B, scaled down for larger sizes) to dampen variance
across roughly one second of wall time. Output is parseable `key=value`
lines so external collectors can scrape them. Timing uses
`std.os.linux.clock_gettime(.MONOTONIC, &ts)` directly — `std.time.Timer` and
`std.time.nanoTimestamp` were removed in Zig 0.16's stdlib reshuffle.

Representative numbers on the maintainer's workstation
(Intel Core i7-1065G7 @ 1.30 GHz, Linux 7.0.3-arch1-1 x86_64, Zig 0.16.0,
`zig build bench` with `-Doptimize=ReleaseFast`). Throughput is in *payload*
bytes/sec; the actual wire frame is larger by the 20-byte header+CRC plus
~0.4% COBS overhead:

| Bench       | Payload | ns/op  | MB/s | pkts/s        |
| ----------- | ------- | ------ | ---- | ------------- |
| encode      | 16 B    | 411    |   38 |               |
| encode      | 256 B   | 3 412  |   75 |               |
| encode      | 1 KiB   | 13 618 |   75 |               |
| decode      | 16 B    | 522    |   30 |               |
| decode      | 256 B   | 5 068  |   50 |               |
| decode      | 1 KiB   | 16 799 |   60 |               |
| roundtrip   | 256 B   | 15 507 |   16 |    64 483     |

The throughput is dominated by the CRC32 pass over header + payload; this
build uses `std.hash.Crc32` (table-based, no SSE4.2 CRC32 intrinsic). A
slice-by-8 or `_mm_crc32` variant would close most of the gap to memcpy
speed; that's deferred until a caller actually needs it.

These numbers are on my workstation; bring your own data.

## License

MIT. See `LICENSE`.

## Contributing

Issues and PRs welcome. Changes that alter the wire format are breaking and
require a version bump. The fixture test in `src/root.zig` is the canonical
specification of v1.

## Part of the Sovereign Stack

This is one of a set of small, composable Zig libraries.

- [**zig-cobs**](https://github.com/SMC17/zig-cobs) — the underlying COBS framing this protocol uses
- [**zig-graph**](https://github.com/SMC17/zig-graph) — sparse graph + spectral algorithms
- [**zig-h3**](https://github.com/SMC17/zig-h3) — H3 v4 spatial index

See [github.com/SMC17](https://github.com/SMC17) for the full portfolio.
