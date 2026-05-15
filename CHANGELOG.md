## Unreleased

### Honesty correction — 2026-05-15

Prior `v1.0` / "production-grade hygiene milestone" framing was a
Type-I error class per the no-premature-production-claims doctrine:

- **Zig itself is on 0.16, not 1.0.** No Zig library can credibly claim
  API stability beyond "stable on Zig 0.16 today" until the language
  itself ships 1.0. The v1.x git tag is honored for changelog
  continuity, but every reader should treat this as **pre-1.0 in semver
  spirit** until both that gate and a real-deployment gate close.
- **Zero production deployment exists.** No real-traffic operation, no
  soak time, no incident history. The hygiene work
  (LICENSE / SECURITY / CONTRIBUTING / CI / CODE_OF_CONDUCT / dependabot
  / CODEOWNERS) is real. The production claim it implied **wasn't
  earned.**

Going forward, the AGENT_HARNESS proof vocabulary (`scaffold` /
`compiled` / `unit-tested` / `integration-tested` / `audited` /
`benchmarked` / `hardware-verified`) is used strictly. See `STATUS.md`
for the per-component proof index + the gates (G1 hardware-verified
throughput on an MCU + a committed `bench/RESULTS.md`, G2 soak time,
G3 independent protocol/security review, G4 Zig 1.0) that would
justify a stronger claim.

### Added
- Documentation tests (`zig build doctest`, backed by `tools/doctest.sh`).
  Vendors the README Quickstart block into `examples/quickstart.zig` and
  diff-checks the two on every invocation, so drift between README and
  executable source fails CI. Also asserts the quickstart binary prints
  the documented `wire: N bytes` line on stdout, and verifies the
  documented build steps (`test`, `bench`, `example-echo`) actually exist
  in `zig build --help`. First-pass discipline: one code block locked in,
  five checks total. The README and the vendored example agreed on first
  run — no drift to report. Follow-ups can tighten the doc-test surface
  to cover the wire-format table, API signature blocks, and bench output
  format.
- `zig build example-quickstart` — runs the vendored README Quickstart.

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
