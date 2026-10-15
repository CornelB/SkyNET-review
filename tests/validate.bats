#!/usr/bin/env bats
# Report validation: what counts as a report.

load test_helper

v() { . "$SCRIPTS/lib/common.sh"; rc_validate_report "$1" "$2"; }

setup() {
  setup_env
  OUT="$BATS_TEST_TMPDIR/r.md" LOG="$BATS_TEST_TMPDIR/r.log"
  : >"$OUT"; : >"$LOG"
}

@test "verdict on line 1 is ok" {
  printf 'Verdict: pass\nNot checked: nothing.\n' >"$OUT"
  run v "$OUT" "$LOG"
  [ "$output" = "ok|$OUT" ]
}

@test "markdown-decorated verdict and leading blank lines are ok" {
  printf '\n\n**Verdict:** fail\n' >"$OUT"
  run v "$OUT" "$LOG"
  [[ "$output" == ok\|* ]]
}

@test "empty report" {
  run v "$OUT" "$LOG"
  [[ "$output" == "did-not-report|empty report"* ]]
}

@test "preamble before the verdict" {
  printf 'Sure! Here is the review.\nVerdict: pass\n' >"$OUT"
  run v "$OUT" "$LOG"
  [[ "$output" == "did-not-report|no verdict on line 1"* ]]
}

@test "rejected invocation in the report file, even with exit 0" {
  printf 'error: unknown effort level max (use one of: xhigh, high)\n' >"$OUT"
  run v "$OUT" "$LOG"
  [[ "$output" == "did-not-report|CLI rejected the invocation"* ]]
}

@test "usage dump at the top of the log" {
  printf 'Verdict: pass\n' >"$OUT"
  printf 'Usage: codex exec [OPTIONS]\n' >"$LOG"
  run v "$OUT" "$LOG"
  [[ "$output" == "did-not-report|CLI rejected the invocation"* ]]
}

@test "headless permission denial" {
  printf 'Verdict: pass\n' >"$OUT"
  printf 'tool call read_file was auto-denied\n' >"$LOG"
  run v "$OUT" "$LOG"
  [[ "$output" == "did-not-report|tool permission denial"* ]]
}

@test "quota text counts in the log only, not in the report" {
  printf 'Verdict: pass with concerns\n1. api.ts:L3 | 🟡 risk | no handling when quota exceeded. Add 429 branch.\n' >"$OUT"
  run v "$OUT" "$LOG"
  [[ "$output" == ok\|* ]]
  printf 'Error: usage limit reached\n' >"$LOG"
  run v "$OUT" "$LOG"
  [[ "$output" == "did-not-report|quota or auth limit"* ]]
}
