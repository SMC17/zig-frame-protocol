# Changelog

All notable changes to `zig-cobs` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] — 2026-05-13

Initial release.

### Added
- `encode(src, dst)` — COBS encoder writing into a caller-provided buffer.
- `decode(src, dst)` — COBS decoder writing into a caller-provided buffer.
- `maxEncodedLength(input_len)` — exact worst-case encoded size, suitable
  for sizing destination buffers at the call site.
- `Error` enum: `BufferTooSmall`, `InvalidEncoding`.
- Property-based roundtrip tests across input lengths 0–2048 with
  pseudo-random payloads.
- Boundary tests at the 254 and 255 byte overhead breakpoints.
- Encoded-output invariant test confirming no `0x00` bytes in any frame.
- Buffer-undersize and malformed-frame rejection tests for both `encode`
  and `decode`.

### Fixed (vs. internal predecessor implementations)
- Bounds check in `encode` previously read `dst.len < src.len + 2`, which
  was too permissive for inputs whose worst-case encoded length exceeds
  `src.len + 1`. The check now uses `maxEncodedLength(src.len)` directly.
