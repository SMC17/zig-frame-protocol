// examples/quickstart.zig
//
// This file is the README "Quickstart" code block, vendored verbatim
// (lines 79..106 of README.md). It exists so the documentation claim is
// EXECUTABLE: `tools/doctest.sh` extracts the block from README and
// diffs against this file; drift between README and code FAILS the
// doc-test. The build wires this as `zig build example-quickstart`,
// which compiles + runs the program and asserts a non-zero exit
// signals a regression.
//
// If you edit the README Quickstart, you MUST update this file too.
// Conversely, if you change the API, you MUST update the README
// Quickstart. The doctest enforces the contract.

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
