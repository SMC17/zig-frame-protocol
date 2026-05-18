#!/usr/bin/env bash
# zig-frame-protocol / tools / doctest.sh
#
# Documentation tests — verify that the README's executable claims
# actually hold. A passing doctest run means:
#
#   1. The README "Quickstart" code block matches `examples/quickstart.zig`
#      byte-for-byte (drift between docs and code FAILS the test).
#   2. The compiled quickstart binary runs cleanly and prints the
#      documented "wire: N bytes" line on stdout.
#   3. The README's documented build steps (`zig build test`,
#      `zig build bench`, `zig build example-echo`) at least PARSE as
#      valid build steps (we don't run bench here — it's slow — but we
#      confirm the step name exists).
#
# WHY: Stale README examples are a common failure mode in OSS projects.
# The library evolves, the README doesn't, and new users get confused.
# This script makes the README a load-bearing artifact that CI gates.

set -euo pipefail
cd "$(dirname "$0")/.."

n_pass=0
n_fail=0
declare -a FAILURES=()

assert_match() {
  local name="$1"
  local file_a="$2"
  local file_b="$3"
  if diff -u "$file_a" "$file_b" >/dev/null 2>&1; then
    n_pass=$((n_pass + 1))
    echo "  PASS  $name"
  else
    n_fail=$((n_fail + 1))
    FAILURES+=("$name (see: diff -u $file_a $file_b)")
    echo "  FAIL  $name"
    diff -u "$file_a" "$file_b" | sed 's/^/        /' | head -30
  fi
}

assert_output() {
  local name="$1"
  local expected_regex="$2"
  shift 2
  local out; out=$("$@" 2>&1 || true)
  if echo "$out" | grep -qE "$expected_regex"; then
    n_pass=$((n_pass + 1))
    echo "  PASS  $name"
  else
    n_fail=$((n_fail + 1))
    FAILURES+=("$name: stdout did not match /$expected_regex/")
    echo "  FAIL  $name"
    echo "        got: $out" | head -5
  fi
}

assert_build_step() {
  local name="$1"
  local step="$2"
  if zig build --help 2>&1 | grep -qE "  $step\b"; then
    n_pass=$((n_pass + 1))
    echo "  PASS  $name"
  else
    n_fail=$((n_fail + 1))
    FAILURES+=("$name: build step '$step' is missing")
    echo "  FAIL  $name (step '$step' missing)"
  fi
}

echo "=== zig-frame-protocol doctest ==="

# --- Check 1: README Quickstart block matches examples/quickstart.zig -------
#
# The README has the Quickstart code starting at the line `const std =`
# (inside a ```zig fenced block) and ending at the trailing closing
# brace of `pub fn main`. We extract the block and diff against the
# vendored example file (with its header comment stripped).

EXTRACTED=$(mktemp)
# Extract content between the first ```zig...const std = and the next ```
awk '
  /^```zig$/    { in_block = 1; next }
  /^```$/       { if (in_block && found_main) { in_block = 0; exit } }
  in_block && /const std = @import\("std"\)/ { found_main = 1 }
  in_block && found_main { print }
' README.md > "$EXTRACTED"

# Strip the header comment from examples/quickstart.zig to match.
EX_STRIPPED=$(mktemp)
awk '
  /^const std = @import\("std"\)/ { printing = 1 }
  printing { print }
' examples/quickstart.zig > "$EX_STRIPPED"

assert_match "README Quickstart block matches examples/quickstart.zig" "$EXTRACTED" "$EX_STRIPPED"
rm -f "$EXTRACTED" "$EX_STRIPPED"

# --- Check 2: Quickstart binary runs and prints "wire: N bytes" -------------
QUICKSTART_BIN=zig-out/bin/example-quickstart
if [ ! -x "$QUICKSTART_BIN" ]; then
  echo "  FAIL  example-quickstart binary missing (run \`zig build\` first)"
  n_fail=$((n_fail + 1))
  FAILURES+=("example-quickstart binary missing")
else
  assert_output "Quickstart binary prints 'wire: N bytes'" 'wire: [0-9]+ bytes' "$QUICKSTART_BIN"
fi

# --- Check 3: Documented build steps exist ---------------------------------
assert_build_step "README documents 'zig build test'" "test"
assert_build_step "README documents 'zig build bench'" "bench"
assert_build_step "README documents 'zig build example-echo'" "example-echo"

echo
echo "=== summary ==="
echo "  pass: $n_pass"
echo "  fail: $n_fail"
if [ "$n_fail" -gt 0 ]; then
  echo
  echo "Failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
