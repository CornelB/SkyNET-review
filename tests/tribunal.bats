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
  grep -q '"claude_model":"fable","claude_effort":"medium","codex_model":"gpt-6-astra","codex_effort":"low"' "$d/status.json"
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

@test "codex: an installed ai-usage skill wins over the codex read" {
  fake_codex
  d=$(prepared_run)
  mkdir -p "$HOME/.agents/skills/ai-usage/scripts"
  printf '%s\n' 'print("[{\"provider\": \"codex\", \"source\": \"oauth\", \"windows\": [{\"name\": \"week\", \"used_percent\": 70.2, \"window_minutes\": 10080, \"resets_at\": \"2099-01-01T00:00:00Z\"}]}]")' \
    >"$HOME/.agents/skills/ai-usage/scripts/ai_usage.py"
  FAKE_CODEX_WEEK=10 run tribunal run -s codex "$d"
  grep -q '|ok|gpt-6.1-sol, xhigh, week 71% (ai-usage)' "$d/reports/security.codex.status"
}

@test "codex: the skynet plugin's usage skill wins over an old ai-usage skill" {
  fake_codex
  d=$(prepared_run)
  root="$HOME/.claude/plugins/cache/local/skynet/0.1.0"
  mkdir -p "$root/skills/usage/scripts" "$HOME/.agents/skills/ai-usage/scripts"
  printf '{"version": 2, "plugins": {"skynet@local": [{"installPath": "%s"}]}}\n' "$root" >"$HOME/.claude/plugins/installed_plugins.json"
  printf '%s\n' 'print("[{\"provider\": \"codex\", \"source\": \"oauth\", \"windows\": [{\"name\": \"week\", \"used_percent\": 80.1, \"window_minutes\": 10080, \"resets_at\": \"2099-01-01T00:00:00Z\"}]}]")' \
    >"$root/skills/usage/scripts/ai_usage.py"
  printf '%s\n' 'print("[]")' >"$HOME/.agents/skills/ai-usage/scripts/ai_usage.py"
  FAKE_CODEX_WEEK=10 run tribunal run -s codex "$d"
  grep -q '|ok|gpt-6.1-sol, xhigh, week 81% (ai-usage)' "$d/reports/security.codex.status"
}

@test "-m and -e reach the claude-cli seat" {
  fake_claude
  d=$(prepared_run)
  run tribunal run -s claude-cli -m fable -e medium "$d"
  [ "$status" -eq 0 ]
  grep -q '"claude_model":"fable","claude_effort":"medium"' "$d/status.json"
  grep -q '|ok|fable, medium, plan mode' "$d/reports/security.claude-cli.status"
}

@test "claude-cli: a 400 on the chosen model reruns the lens on opus xhigh" {
  cat >"$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
[ "$1" = auth ] && exit 0
cat >/dev/null
case " $* " in
  *" --model fable "*) echo 'API Error: 400 {"message":"must have data retention enabled"}'; exit 1 ;;
esac
printf 'Verdict: pass\nNot checked: nothing.\n'
EOF
  chmod +x "$FAKEBIN/claude"
  d=$(prepared_run)
  run tribunal run -s claude-cli "$d"
  [ "$status" -eq 0 ]
  grep -q '|ok|opus, xhigh (fable rejected: API Error 400), plan mode' "$d/reports/security.claude-cli.status"
  head -n 1 "$d/reports/security.claude-cli.md" | grep -qx 'Verdict: pass'
  grep -q 'retrying on opus xhigh' "$d/reports/security.claude-cli.log"
}

@test "grok: a spent usage quota skips the seat at pre-flight" {
  cat >"$FAKEBIN/grok" <<'EOF'
#!/usr/bin/env bash
echo "start" >>"$FAKE_LOG"
echo "Error: You've reached your free Grok Build usage limit for now." >&2
exit 1
EOF
  chmod +x "$FAKEBIN/grok"
  d=$(prepared_run)
  run tribunal run -s grok "$d"
  [ "$status" -eq 0 ]
  grep -q '^security|grok|skipped|usage limit reached' "$d/reports/security.grok.status"
  [ "$(grep -c start "$FAKE_LOG")" -eq 1 ]
}

@test "grok: the report is the final message, not the progress lines before it" {
  cat >"$FAKEBIN/grok" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' \
  '{"type":"system","subtype":"init"}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"I will read the diff."},{"type":"tool_use","name":"read_file"}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"Verdict: pass\nNot checked: nothing."}]}}' \
  '{"type":"result","subtype":"success","result":"Verdict: pass\nNot checked: nothing."}'
EOF
  chmod +x "$FAKEBIN/grok"
  d=$(prepared_run)
  run tribunal run -s grok "$d"
  [ "$status" -eq 0 ]
  grep -q '^security|grok|ok|' "$d/reports/security.grok.status"
  [ "$(head -n 1 "$d/reports/security.grok.md")" = "Verdict: pass" ]
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

# A fake ollama whose `show` reports a trained context of 131072 and, when
# FAKE_NUM_CTX is set, that num_ctx parameter.
fake_ollama_show() {
  cat >"$FAKEBIN/ollama" <<'EOS'
#!/usr/bin/env bash
[ "${1:-}" = show ] || exit 0
printf '  Model\n    context length      131072\n\n'
[ -n "${FAKE_NUM_CTX:-}" ] && printf '  Parameters\n    num_ctx        %s\n' "$FAKE_NUM_CTX"
exit 0
EOS
  chmod +x "$FAKEBIN/ollama"
}

@test "codex-oss is skipped when the diff exceeds the model context" {
  fake_codex; fake_ollama_show
  d=$(prepared_run)
  bytes=$(wc -c <"$d/diff.patch" | tr -cd '0-9')
  small=$(( (bytes + 3) / 4 - 1 ))
  OLLAMA_REVIEWER_MODEL=m FAKE_NUM_CTX=$small run tribunal run -s codex-oss "$d"
  [ "$status" -eq 3 ]
  [[ "$output" == *"codex-oss|diff ~$((small + 1)) tokens exceeds m context of $small"* ]]
  [ ! -s "$FAKE_LOG" ]
  OLLAMA_REVIEWER_MODEL=m FAKE_NUM_CTX=$((small + 1)) run tribunal run -s codex-oss "$d"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'start oss' "$FAKE_LOG")" -eq 4 ]
}

@test "codex-oss context: 4096 without num_ctx, capped at the trained length" {
  fake_codex; fake_ollama_show
  d=$(prepared_run)
  head -c 20000 /dev/zero | tr '\0' x >>"$d/diff.patch"
  OLLAMA_REVIEWER_MODEL=m run tribunal start -s codex-oss "$d"
  [ "$status" -eq 3 ]
  [[ "$output" == *"exceeds m context of 4096"* ]]
  OLLAMA_REVIEWER_MODEL=m OLLAMA_CONTEXT_LENGTH=1000 run tribunal start -s codex-oss "$d"
  [[ "$output" == *"exceeds m context of 1000"* ]]
  head -c 600000 /dev/zero | tr '\0' x >>"$d/diff.patch"
  OLLAMA_REVIEWER_MODEL=m FAKE_NUM_CTX=999999 run tribunal start -s codex-oss "$d"
  [ "$status" -eq 3 ]
  [[ "$output" == *"exceeds m context of 131072"* ]]
}
