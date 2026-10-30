#!/usr/bin/env bash
#
# mayhem/test.sh — RUN nghttp2's OWN munit suite (already built by mayhem/build.sh). exit 0 = pass. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

RUNNER="$SRC/build/tests/nghttp2_tests"
[ -x "$RUNNER" ] || { echo "missing $RUNNER (mayhem/build.sh should have built it)" >&2; exit 2; }

# The suite asserts known values for frame pack/unpack, HPACK, session state machine, etc. A neutered
# runner prints nothing, so zero parsed results is a failure, never a pass.
out=$("$RUNNER" --seed 0x1234 --color never 2>&1); rc=$?
printf '%s\n' "$out" | tail -n 5
passed=$(printf '%s\n' "$out" | grep -c '\[ OK    \]' || true)
failed=$(printf '%s\n' "$out" | grep -cE '\[ (FAIL|ERROR) ' || true)
skipped=$(printf '%s\n' "$out" | grep -c '\[ SKIP  \]' || true)
summary=$(printf '%s\n' "$out" | grep -E '^[0-9]+ of [0-9]+ \(' | tail -n1)
total=$(printf '%s\n' "$summary" | sed -E 's/^[0-9]+ of ([0-9]+) .*/\1/')

if [ -z "$summary" ] || [ "${total:-0}" -lt 100 ] || [ "$((passed + failed + skipped))" -ne "$total" ]; then
  echo "unexpected test output (summary='$summary', parsed=$((passed + failed + skipped)))" >&2
  emit_ctrf "munit" "$passed" "$((failed + 1))" "$skipped"
  exit 1
fi
[ "$rc" -eq 0 ] || failed=$((failed > 0 ? failed : 1))
emit_ctrf "munit" "$passed" "$failed" "$skipped"
