## v1.0.0 — 2026-05-13

**Production-grade hygiene milestone.**

- Added SECURITY.md (coordinated disclosure policy).
- Verified LICENSE, README, CONTRIBUTING, CODE_OF_CONDUCT, CI workflow all in place and accurate.
- API surface declared stable for the v1.x cycle. Breaking changes will bump to v2.x.
- Engineering posture: Virgil work-in-progress convention adapted for OSS — v1.0 means we stand behind the existing surface; v1.x patches refine implementation without breaking the API.

# Changelog

All notable changes to `zig-frame-protocol` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] — 2026-05-13

Initial release.

### Added
- `encode(out, scratch, kind, sequence, node_ms, payload)` — convenience that
  builds a packet and COBS-encodes it in one call.
- `decode(wire, scratch)` — strip optional trailing `0x00`, COBS-decode into
  `scratch`, parse the packet, return a `Frame`.
- `buildPacket` / `encodePacket` / `parsePacket` — lower-level primitives for
  callers that want to manage scratch ownership themselves.
- `packetLen` / `maxEncodedLen` — sizing helpers for caller-provided buffers.
- `Frame` struct: `kind`, `sequence`, `node_ms`, `payload` slice.
- `Error` enum: `PayloadTooLarge`, `BufferTooSmall`, `Truncated`,
  `InvalidEncoding`, `UnsupportedVersion`, `PayloadLengthMismatch`,
  `ChecksumMismatch`.
- 15 tests covering size math, roundtrips at multiple payload lengths,
  property-based roundtrip across 0–1024 bytes, all error paths, and a
  byte-fixture test pinning the v1 wire format.

### Dependencies
- `zig-cobs` `^0.1.0`
