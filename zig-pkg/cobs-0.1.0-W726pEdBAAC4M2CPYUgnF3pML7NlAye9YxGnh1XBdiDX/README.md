# zig-cobs

Consistent Overhead Byte Stuffing (COBS) framing in pure Zig. Zero allocation,
no dependencies, suitable for embedded targets and high-throughput stream
framing on hosts.

COBS turns an arbitrary byte stream into a zero-free encoded form so that a
single `0x00` byte can be used as an unambiguous frame delimiter. Worst-case
overhead is `1 + ceil(len / 254)` bytes — about 0.4% on long payloads.

Reference: Cheshire & Baker, [Consistent Overhead Byte Stuffing][cobs-paper]
(SIGCOMM 1997).

[cobs-paper]: http://www.stuartcheshire.org/papers/COBSforToN.pdf

## Status

`v0.1.0` — initial release. Encode and decode are correct against the
reference algorithm and pass property-based roundtrip tests across lengths
0 through 2048 with pseudo-random payloads, plus boundary cases at the 254
and 255 byte overhead breakpoints.

Minimum Zig version: `0.15.0`. Tested on Zig `0.16.0`.

## Install

Add `zig-cobs` to your `build.zig.zon` dependencies:

```zig
.dependencies = .{
    .cobs = .{
        .url = "https://github.com/SMC17/zig-cobs/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in `build.zig`:

```zig
const cobs = b.dependency("cobs", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("cobs", cobs.module("cobs"));
```

## Quickstart

```zig
const std = @import("std");
const cobs = @import("cobs");

pub fn main() !void {
    const payload = "hello\x00world";

    // Size the output buffer using the worst-case formula.
    var encoded: [cobs.maxEncodedLength(payload.len)]u8 = undefined;
    const enc_len = try cobs.encode(payload, &encoded);

    // Encoded form contains no zero bytes; append a 0x00 delimiter when
    // transmitting over a stream.
    std.debug.print("encoded {} bytes\n", .{enc_len});

    var decoded: [payload.len]u8 = undefined;
    const dec_len = try cobs.decode(encoded[0..enc_len], &decoded);

    std.debug.assert(std.mem.eql(u8, payload, decoded[0..dec_len]));
}
```

## API

```zig
pub fn maxEncodedLength(input_len: usize) usize;
pub fn encode(src: []const u8, dst: []u8) Error!usize;
pub fn decode(src: []const u8, dst: []u8) Error!usize;

pub const Error = error{
    BufferTooSmall,
    InvalidEncoding,
};
```

- `maxEncodedLength` — exact worst-case size of an encoded buffer for an
  input of `input_len` bytes. Use it to size `dst` for `encode`.
- `encode` — write the COBS-encoded form of `src` into `dst`. Returns the
  number of bytes written. `dst.len` must be at least
  `maxEncodedLength(src.len)`; otherwise returns `error.BufferTooSmall`.
  Encoded output never contains a `0x00` byte.
- `decode` — write the decoded payload of a COBS frame `src` into `dst`.
  Returns the number of payload bytes written. `src` must not contain a
  `0x00` byte; if it does, returns `error.InvalidEncoding`. The frame
  delimiter `0x00` is *not* part of `src` — strip it before calling.

## Tests

```sh
zig build test
```

Includes:

- Boundary cases at empty input, single-zero, single-non-zero, 254-byte runs
  (no overhead injection), 255-byte runs (overhead byte injected).
- Encoded-output invariant: no `0x00` bytes in any encoded frame.
- Buffer-undersize rejection on both `encode` and `decode`.
- Malformed-frame rejection (zero byte mid-frame, truncated frame).
- Property-based roundtrip across lengths 0–2048 with pseudo-random payloads.
- Property-based check that `encode` output is always `≤ maxEncodedLength`.

## Use cases

- Serial / UART framing over MCUs (ESP32, STM32, RP2040)
- Sensor data streams over unreliable links
- USB CDC or BLE characteristic stream framing
- Any byte stream where a single-byte unambiguous frame delimiter is desired

## Why no allocator parameter

`encode` and `decode` operate strictly on caller-provided buffers. This keeps
the library usable on `freestanding` targets, in interrupt handlers, and in
contexts where allocator failure is not an option. Compute the required buffer
size with `maxEncodedLength` at the call site.

## License

MIT. See `LICENSE`.

## Contributing

Issues and PRs welcome. The code surface is intentionally small; changes
should preserve zero-allocation, freestanding-friendly, and `O(n)` time
properties.
