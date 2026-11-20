#!/usr/bin/env bats
# Seat discovery and gating, including the codex-oss gate.

load test_helper

discover() { "$HOST_BASH" "$SCRIPTS/run-tribunal.sh" discover "$@"; }

@test "no CLIs: every seat disabled with its reason" {
  run discover
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 7 ]
  [[ "${lines[0]}" == "codex|disabled|codex not on PATH" ]]
  [[ "${lines[1]}" == "antigravity|disabled|agy not on PATH" ]]
  [[ "${lines[2]}" == "grok|disabled|grok not on PATH" ]]
  [[ "${lines[3]}" == "claude-cli|disabled|claude not on PATH" ]]
  [[ "${lines[4]}" == "kimi-cli|disabled|kimi not on PATH" ]]
  [[ "${lines[5]}" == "cursor-cli|disabled|cursor-agent not on PATH" ]]
  [[ "${lines[6]}" == "codex-oss|disabled|codex not on PATH" ]]
}

@test "each seat is available once its CLI is on PATH" {
  fake_codex; fake_plain agy; fake_plain grok; fake_claude; fake_plain kimi; fake_plain cursor-agent
  run discover
  [ "$status" -eq 0 ]
  for s in codex antigravity grok claude-cli kimi-cli cursor-cli; do
    [[ "$output" == *"$s|available|"* ]]
  done
}

@test "codex-oss: codex alone is not enough" {
  fake_codex
  run discover -s codex-oss
  [ "$output" = "codex-oss|disabled|ollama not on PATH" ]
}

@test "codex-oss: codex and ollama without OLLAMA_REVIEWER_MODEL" {
  fake_codex; fake_plain ollama
  run discover -s codex-oss
  [ "$output" = "codex-oss|disabled|OLLAMA_REVIEWER_MODEL not set" ]
}

@test "codex-oss: available with codex, ollama and the model set" {
  fake_codex; fake_plain ollama
  OLLAMA_REVIEWER_MODEL=qwen3-coder run discover -s codex-oss
  [ "$output" = "codex-oss|available|ollama qwen3-coder, read-only sandbox" ]
}

@test "codex: the status line shows the model rule and the weekly usage" {
  fake_codex
  FAKE_CODEX_WEEK=12 run discover -s codex
  [ "$output" = "codex|available|gpt-6-astra, low, week 12% (live), read-only sandbox" ]
}

@test "codex: a full 5h or weekly window disables the seat" {
  fake_codex
  FAKE_CODEX_5H=89 FAKE_CODEX_WEEK=94 run discover -s codex
  [ "$output" = "codex|available|gpt-6.1-sol, xhigh, week 94% (live), read-only sandbox" ]
  FAKE_CODEX_5H=90 FAKE_CODEX_WEEK=12 run discover -s codex
  [ "$output" = "codex|disabled|codex usage full: 5h 90%, resets unknown" ]
  FAKE_CODEX_WEEK=95 run discover -s codex
  [ "$output" = "codex|disabled|codex usage full: week 95%, resets unknown" ]
}

@test "codex: a full 5h window from the usage skill disables the seat" {
  fake_codex
  mkdir -p "$HOME/.agents/skills/ai-usage/scripts"
  printf '%s\n' 'print("[{\"provider\": \"codex\", \"source\": \"oauth\", \"windows\": [{\"name\": \"5h\", \"used_percent\": 100, \"window_minutes\": 300, \"resets_at\": \"2099-01-01T12:00:00Z\"}, {\"name\": \"week\", \"used_percent\": 40, \"window_minutes\": 10080, \"resets_at\": \"2099-01-05T00:00:00Z\"}]}]")' \
    >"$HOME/.agents/skills/ai-usage/scripts/ai_usage.py"
  TZ=UTC run discover -s codex
  [ "$output" = "codex|disabled|codex usage full: 5h 100%, resets 12:00" ]
}

@test "claude-cli: unauthenticated claude is disabled" {
  printf '#!/usr/bin/env bash\nexit 1\n' >"$FAKEBIN/claude"; chmod +x "$FAKEBIN/claude"
  run discover -s claude-cli
  [[ "$output" == "claude-cli|disabled|claude not authenticated"* ]]
}

@test "-s keeps canonical order and rejects unknown seats" {
  fake_codex; fake_plain grok
  run discover -s grok,codex
  [ "${lines[0]%%|*}" = codex ]
  [ "${lines[1]%%|*}" = grok ]
  run discover -s gemini
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown seat: gemini"* ]]
}

@test "seat script without a gate skips instead of running" {
  run "$HOST_BASH" "$SCRIPTS/seats/kimi-cli.sh" -w "$BATS_TEST_TMPDIR" -p "$BATS_TEST_DIRNAME/test_helper.bash" -o "$BATS_TEST_TMPDIR/r.md" -t 5
  [ "$status" -eq 0 ]
  [ "$output" = "kimi-cli|skipped|kimi not on PATH" ]
}

@test "seat script refuses a bad invocation" {
  run "$HOST_BASH" "$SCRIPTS/seats/codex.sh" -w "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
  run "$HOST_BASH" "$SCRIPTS/seats/codex.sh" -w "$BATS_TEST_TMPDIR" -p x -o y -t soon
  [ "$status" -eq 2 ]
}

@test "codex-oss: a selected server is named and checked with ollama show there" {
  fake_codex; fake_ollama_show; fake_selector 'echo 127.0.0.1:11435'
  OLLAMA_REVIEWER_MODEL=qwen3-coder run discover -s codex-oss
  [ "$output" = "codex-oss|available|ollama qwen3-coder @ http://127.0.0.1:11435, read-only sandbox" ]
  [ "$(cat "$FAKE_LOG.selector")" = "review qwen3-coder" ]
  grep -qx 'http://127.0.0.1:11435' "$FAKE_LOG.ollama_host"
}

@test "codex-oss: an empty selector answer keeps the default server" {
  fake_codex; fake_ollama_show; fake_selector 'exit 0'
  OLLAMA_REVIEWER_MODEL=qwen3-coder run discover -s codex-oss
  [ "$output" = "codex-oss|available|ollama qwen3-coder, read-only sandbox" ]
}

@test "codex-oss: a selector refusal gates the seat with its reason" {
  fake_codex; fake_ollama_show
  fake_selector 'echo starting >&2; echo busy >&2; exit 1'
  OLLAMA_REVIEWER_MODEL=qwen3-coder run discover -s codex-oss
  [ "$output" = "codex-oss|disabled|busy" ]
  fake_selector 'exit 3'
  OLLAMA_REVIEWER_MODEL=qwen3-coder run discover -s codex-oss
  [ "$output" = "codex-oss|disabled|selector exit 3" ]
}

@test "codex-oss: a relative or non-executable selector is refused" {
  fake_codex; fake_ollama_show
  OLLAMA_SELECTOR=rel/select OLLAMA_REVIEWER_MODEL=qwen3-coder run discover -s codex-oss
  [ "$output" = "codex-oss|disabled|OLLAMA_SELECTOR not executable" ]
  printf 'echo x\n' >"$BATS_TEST_TMPDIR/plain"
  OLLAMA_SELECTOR="$BATS_TEST_TMPDIR/plain" OLLAMA_REVIEWER_MODEL=qwen3-coder run discover -s codex-oss
  [ "$output" = "codex-oss|disabled|OLLAMA_SELECTOR not executable" ]
}

@test "codex-oss: a malformed selector answer is refused with the line" {
  fake_codex; fake_ollama_show; fake_selector 'echo nope'
  OLLAMA_REVIEWER_MODEL=qwen3-coder run discover -s codex-oss
  [ "$output" = "codex-oss|disabled|selector printed nope" ]
}

@test "codex-oss: a reason loses control characters and pipes" {
  fake_codex; fake_ollama_show
  fake_selector 'printf "\033[31ma|b\r\n" >&2; exit 1'
  OLLAMA_REVIEWER_MODEL=qwen3-coder run discover -s codex-oss
  [ "$output" = "codex-oss|disabled|[31ma/b" ]
}

@test "codex-oss: a server that cannot show the model is refused" {
  fake_codex; fake_ollama_show; fake_selector 'echo 127.0.0.1:11435'
  FAKE_SHOW_FAIL=1 OLLAMA_REVIEWER_MODEL=qwen3-coder run discover -s codex-oss
  [ "$output" = "codex-oss|disabled|qwen3-coder not served by http://127.0.0.1:11435" ]
}

@test "codex-oss: a selector over the 10 s cap is refused" {
  fake_codex; fake_ollama_show; fake_selector 'sleep 30'
  OLLAMA_REVIEWER_MODEL=qwen3-coder run discover -s codex-oss
  [ "$output" = "codex-oss|disabled|selector timed out" ]
}

@test "codex-oss: a background child of the selector does not hold the gate" {
  fake_codex; fake_ollama_show; fake_selector 'sleep 30 & echo 127.0.0.1:11435'
  t0=$(date +%s)
  OLLAMA_REVIEWER_MODEL=qwen3-coder run discover -s codex-oss
  [ $(( $(date +%s) - t0 )) -lt 5 ]
  [[ "$output" == "codex-oss|available|"* ]]
}

@test "codex-oss: without OLLAMA_REVIEWER_MODEL the selector is not asked" {
  fake_codex; fake_ollama_show; fake_selector 'echo 127.0.0.1:11435'
  run discover -s codex-oss
  [ "$output" = "codex-oss|disabled|OLLAMA_REVIEWER_MODEL not set" ]
  [ ! -e "$FAKE_LOG.selector" ]
}
