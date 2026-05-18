#!/usr/bin/env bash
# tools/coverage.sh — measure line coverage of src/root.zig via kcov.
#
# Why a wrapper: the Zig 0.16 test runner's debug-info layout currently
# does not surface line-coverage to kcov on the nixpkgs build (which is
# compiled without libbfd-dev). Running kcov against a plain executable
# (the `coverage-driver` exe defined in build.zig + examples/) works
# cleanly because it has standard ELF + DWARF, no test-runner inlining.
#
# The driver exercises every public function and every public error
# path in src/root.zig — see examples/coverage_driver.zig.
#
# Usage:
#   bash tools/coverage.sh             # build + run + print line %
#   bash tools/coverage.sh --html      # also keep the HTML report
#
# Requires: kcov, jq, zig 0.16.

set -euo pipefail

OUT_DIR="${COVERAGE_OUT_DIR:-coverage-out}"
KEEP_HTML="${1:-}"

# Build the coverage driver. Use Debug so kcov sees the DWARF info.
zig build install -Doptimize=Debug

if ! command -v kcov >/dev/null 2>&1; then
    echo "tools/coverage.sh: kcov not on PATH" >&2
    echo "On NixOS, run inside: nix-shell -p kcov --run 'bash tools/coverage.sh'" >&2
    exit 2
fi

rm -rf "$OUT_DIR"
kcov --include-pattern=root.zig "$OUT_DIR" ./zig-out/bin/coverage-driver

# Locate coverage.json — older kcov (Ubuntu 22.04 ships v38) writes only
# the per-run hashed subdir; newer kcov (NixOS v43) also writes the
# canonical `<exe-name>/coverage.json`. Find whichever exists.
report=$(find "$OUT_DIR" -name coverage.json -type f | sort | head -1)
if [[ -z "$report" ]]; then
    echo "tools/coverage.sh: kcov produced no coverage.json under $OUT_DIR" >&2
    find "$OUT_DIR" -type f 2>/dev/null | head -10 >&2
    exit 2
fi

pct=$(jq -r '.percent_covered' "$report")
covered=$(jq -r '.covered_lines' "$report")
total=$(jq -r '.total_lines' "$report")

echo
echo "src/root.zig line coverage: $pct% ($covered/$total)"
echo "  HTML report: $OUT_DIR/coverage-driver/index.html"

if [[ "$KEEP_HTML" != "--html" ]]; then
    : # default behaviour: keep everything
fi

# Lightweight floor — fail the script if coverage drops below 80%.
# The current floor matches the substrate after the v1.2.0 instrumentation
# pass; raise this guard as more public API ships.
threshold=80
pct_int=${pct%.*}
if (( pct_int < threshold )); then
    echo "tools/coverage.sh: FAIL — line coverage ${pct}% < threshold ${threshold}%" >&2
    exit 1
fi
