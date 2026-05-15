# zig-frame-protocol status

Last touched: 2026-05-15

## Honest version posture

Despite the `v1.0.0` git tag, this project is **pre-1.0 in semver
spirit** for two independent reasons:

1. **Zig itself is on 0.16, not 1.0.** Until the Zig language hits 1.0,
   no Zig library can credibly claim API stability beyond "stable on
   Zig 0.16 today." Tagging v1.x against a pre-1.0 substrate is a
   vanity claim — the language guarantees aren't there yet.
2. **No production deployment exists.** This library has zero
   real-traffic operation, zero soak time, zero production-incident
   history. "Production-grade hygiene milestone" describes shipping
   process (LICENSE / SECURITY / CONTRIBUTING / CI / CODE_OF_CONDUCT)
   — necessary but **not sufficient** for "production-grade."

The hygiene work is real. The v1.x tag will be honored for changelog
continuity. But every reader should treat this as a pre-1.0 substrate
until both gates above close.

## Proof-vocabulary index (per `~/AGENT_HARNESS.md`)

| component                  | proof level                  | evidence                                                                 |
|----------------------------|------------------------------|--------------------------------------------------------------------------|
| `buildPacket` / `parsePacket` | `unit-tested`             | 15 in-source tests in `src/root.zig` covering size math, roundtrip at multiple payload lengths, property-based roundtrip across 0..1024 bytes, all error paths, plus a v1 wire-format byte-fixture |
| `encode` / `decode`        | `unit-tested`                | Same 15-test suite; convenience wrappers over `buildPacket` / `encodePacket` / `parsePacket` exercised through the roundtrip + fixture tests |
| CRC32 trailer (IEEE 802.3) | `unit-tested`                | `std.hash.Crc32`-based; covered by the byte-fixture test (`test "wire format byte fixture"`) and by `test "decode rejects CRC corruption"` + single-bit-corruption fuzz pass |
| COBS framing wrap          | `unit-tested`                | Delegates to the `zig-cobs` dependency (which has its own proof index); roundtrip + truncation + delimiter-strip tests exercise the wrap surface |
| Fuzz harness               | `audited` (self-consistent)  | `src/fuzz_test.zig` — 6 tests: 10 000 random-roundtrip + 100 000 random-wires-never-panic + bit-corruption + truncation-every-prefix + version-rejection + payload-length-field tampering. Zero panics observed on `decode` of garbage. Trial counts: ~110 K random + N adversarial-prefix passes scaled by canonical-frame count |
| Throughput                 | `compiled`                   | `bench/bench_{encode,decode,roundtrip}.zig` build under `zig build bench` (ReleaseFast). **No published `bench/RESULTS.md` exists yet** — the benches run, but no pinned-hardware numbers have been committed. |
| README/code drift          | `unit-tested`                | `tools/doctest.sh`: 5 checks — Quickstart README block diff vs `examples/quickstart.zig`, quickstart binary stdout-regex `wire: N bytes`, three `zig build --help` step presence checks (`test`, `bench`, `example-echo`) |
| Cross-architecture build   | `compiled` (CI only)         | CI matrix on Linux x86_64 + Linux aarch64 + macOS arm64 (commit `dd42e14`) |

## Gates that would justify a stronger claim

- **G1 — Hardware-verified throughput on an MCU target.** ESP32- or
  STM32-class run with measured throughput + bit-error curve under
  noisy UART / RS-485, plus a committed `bench/RESULTS.md` pinning
  numbers on the host-class hardware the README claims for.
  Status: `NOT YET CLOSED`.
- **G2 — Soak time.** ≥30 days of continuous deployment carrying
  real frames in some real system (mast, a sovereign-stack edge node,
  a telemetry rig — anything that uses the framing in anger). Status:
  `NOT YET CLOSED`.
- **G3 — Independent protocol / security review.** A second pair of
  eyes on the wire format, the CRC placement, the COBS-of-CRC-of-
  payload ordering, and the failure-mode catalog. Ideally someone
  who has shipped framing in production. Status: `NOT YET CLOSED`.
- **G4 — Zig 1.0 reaches stable.** The language-level guarantee that
  makes the v1.x tag mean what it says in any other ecosystem.
  Status: `NOT YET CLOSED` (out of this repo's control).

Only after G4 + at least one of G1 / G2 / G3 do the words "production-
grade" or "stable v1" honestly fit.
