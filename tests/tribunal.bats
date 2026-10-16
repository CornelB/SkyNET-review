#!/usr/bin/env bats
# The tribunal launcher end to end with fake CLIs, and its status output.

load test_helper

tribunal() { "$HOST_BASH" "$SCRIPTS/run-tribunal.sh" "$@"; }
runs() { "$HOST_BASH" "$SCRIPTS/runs.sh" "$@"; }

@test "zero seats: start aborts loudly and launches nothing" {
  d=$(prepared_run)
  run tribunal start "$d"
  [ "$status" -eq 3 ]
  [[ "$output" == *"zero seats available"* ]]
  [[ "$output" == *"codex|disabled|codex not on PATH"* ]]
  [ ! -f "$d/tribunal.pid" ]
  [ -z "$(ls "$d/reports")" ]
}

@test "one seat: four lens cells, validated, status.json done" {
  fake_codex
  d=$(prepared_run)
  run tribunal run "$d"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  for lens in simplicity functionality security maintainability; do
    grep -qx "$lens|codex|ok|gpt-6-astra, low, week usage unknown, read-only sandbox" "$d/reports/$lens.codex.status"
    head -n 1 "$d/reports/$lens.codex.md" | grep -qx 'Verdict: pass'
  done
  grep -q '"state":"done"' "$d/status.json"
  grep -q '"cells_total":4,"cells_done":4' "$d/status.json"
  grep -q '"seats":\["codex"\]' "$d/status.json"
  grep -q '"grok":"grok not on PATH"' "$d/status.json"
  grep -q '"dead":\[\]' "$d/status.json"
  grep -q '"claude_model":"fable","claude_effort":"high","codex_model":"gpt-6-astra","codex_effort":"low"' "$d/status.json"
}

@test "codex: Astra low up to 60% weekly usage, Sol xhigh above" {
  fake_codex
  d=$(prepared_run)
  FAKE_CODEX_WEEK=60 run tribunal run -s codex "$d"
  [ "$status" -eq 0 ]
  grep -q '|ok|gpt-6-astra, low, week 60% (live), read-only sandbox' "$d/reports/security.codex.status"
  [ "$(sort -u "$FAKE_LOG.models")" = gpt-6-astra ]
  : >"$FAKE_LOG.models"
  FAKE_CODEX_WEEK=61 run tribunal run -s codex "$d"
  grep -q '|ok|gpt-6.1-sol, xhigh, week 61% (live), read-only sandbox' "$d/reports/security.codex.status"
  grep -q '"codex_model":"gpt-6.1-sol","codex_effort":"xhigh","codex_usage":"week 61% (live)"' "$d/status.json"
  [ "$(sort -u "$FAKE_LOG.models")" = gpt-6.1-sol ]
}

@test "codex: the last session snapshot stands in when the live read fails" {
  fake_codex
  d=$(prepared_run)
  mkdir -p "$HOME/.codex/sessions/2026/10/16"
  printf '{"timestamp":"2026-10-16T10:00:00Z","payload":{"rate_limits":{"primary":{"used_percent":10,"window_minutes":300,"resets_at":null},"secondary":{"used_percent":75.5,"window_minutes":10080,"resets_at":null}}}}\n' \
    >"$HOME/.codex/sessions/2026/10/16/rollout-1.jsonl"
  run tribunal run -s codex "$d"
  grep -q '|ok|gpt-6.1-sol, xhigh, week 76% (snapshot)' "$d/reports/security.codex.status"
}

@test "-m and -e reach the claude-cli seat" {
  fake_claude
  d=$(prepared_run)
  run tribunal run -s claude-cli -m fable -e medium "$d"
  [ "$status" -eq 0 ]
  grep -q '"claude_model":"fable","claude_effort":"medium"' "$d/status.json"
  grep -q '|ok|fable, medium, plan mode' "$d/reports/security.claude-cli.status"
}

@test "an invalid report is did-not-report and names the dead seat" {
  fake_codex
  d=$(prepared_run)
  FAKE_MODE=noverdict run tribunal run "$d"
  [ "$status" -eq 0 ]
  grep -q '^simplicity|codex|did-not-report|no verdict on line 1' "$d/reports/simplicity.codex.status"
  grep -q '"dead":\["codex"\]' "$d/status.json"
}

@test "codex-oss runs its four lenses one at a time, codex in parallel" {
  fake_codex; fake_plain ollama
  d=$(prepared_run)
  OLLAMA_REVIEWER_MODEL=m FAKE_SLEEP=1 run tribunal run -s codex-oss "$d"
  [ "$status" -eq 0 ]
  # Serialized: every start is followed by its end before the next start.
  [ "$(grep -c 'start oss' "$FAKE_LOG")" -eq 4 ]
  [ "$(tr '\n' ' ' <"$FAKE_LOG")" = "start oss end oss start oss end oss start oss end oss start oss end oss " ]
  : >"$FAKE_LOG"
  FAKE_SLEEP=1 run tribunal run -s codex "$d"
  # Parallel: all four start before the first ends.
  [ "$(head -n 4 "$FAKE_LOG" | grep -c 'start cloud')" -eq 4 ]
}

@test "a timeout with bytes gets one retry at twice the cap, once per seat" {
  fake_codex
  d=$(prepared_run)
  FAKE_MODE=sleep RC_CAP_SECONDS=1 run tribunal run -s codex "$d"
  [ "$status" -eq 0 ]
  [ "$(cat "$d"/reports/*.codex.status | grep -c 'retried at 2s')" -eq 1 ]
  [ "$(cat "$d"/reports/*.codex.status | grep -c '|codex|timeout|')" -eq 4 ]
  grep -q '"cap":1' "$d/status.json"
}

@test "start detaches, wait reports the end, runs.sh lists and shows it" {
  fake_codex
  d=$(prepared_run)
  run tribunal start "$d"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "codex-model|gpt-6-astra|low|week usage unknown" ]
  [[ "${lines[1]}" == started\|*\|"$d" ]]
  run tribunal wait "$d"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "state|done" ]
  [ "${#lines[@]}" -eq 5 ]
  id=$(basename "$d")
  run runs list
  [ "${lines[0]}" = "$id|feature|tribunal|done|4/4|$d" ]
  run runs show "$id"
  [ "${lines[0]}" = "state|done|4/4" ]
  [[ "${lines[1]}" == functionality\|codex\|ok\|*\|"$d/reports/functionality.codex.md" ]]
  printf 'Verdict: pass\n' >"$d/report.md"
  run runs show "$id"
  [ "$output" = "report|$d/report.md" ]
}

@test "cancel stops a running tribunal and marks it cancelled" {
  fake_codex
  d=$(prepared_run)
  FAKE_MODE=sleep run tribunal start "$d"
  [ "$status" -eq 0 ]
  run runs cancel "$(basename "$d")"
  [[ "${lines[0]}" == cancelled\|* ]]
  grep -q '"state":"cancelled"' "$d/status.json"
  ! pgrep -f "$d/prompts" >/dev/null
}

@test "runs.sh: unknown id fails" {
  run runs show review-nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"no run with id review-nope"* ]]
}
