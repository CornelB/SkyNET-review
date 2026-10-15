#!/usr/bin/env bash
# kimi-cli seat: Kimi Code CLI, headless, read tools only. Contract: lib/seat.sh.
set -u
SEAT=kimi-cli
SEAT_DIR="$(cd "$(dirname "$0")" && pwd)"

seat_gate() {
  command -v kimi >/dev/null 2>&1 || { GATE_REASON="kimi not on PATH"; return 1; }
  command -v jq >/dev/null 2>&1 || { GATE_REASON="jq not on PATH (needed to read kimi's stream)"; return 1; }
  return 0
}

seat_describe() { echo "${KIMI_CLI_MODEL:-default model}, read-only agent file"; }

seat_invoke() {
  # `kimi -p` runs under the auto permission policy: every tool it is offered
  # is approved. The agent file offers read tools only and disallows the
  # rest, and the CLI enforces it before execution. --plan cannot combine
  # with -p. stream-json keeps reasoning and the resume footer out of the
  # report; only assistant text without tool calls is kept.
  raw="${OUT%.md}.stream.jsonl"
  kimi -p "$PROMPT" --output-format stream-json --agent-file "$SEAT_DIR/kimi-agent.md" \
    ${KIMI_CLI_MODEL:+-m "$KIMI_CLI_MODEL"} >"$raw" 2>"$LOG" || return $?
  jq -rnR '
    [ inputs | fromjson?
      | select(type == "object" and .role == "assistant" and (has("tool_calls") | not))
      | .content
      | if type == "array" then map(select(.type == "text") | .text // empty) | join("")
        elif type == "string" then . else empty end
    ] | join("")' "$raw" >"$OUT" 2>>"$LOG"
}

# shellcheck source=../lib/seat.sh
. "$SEAT_DIR/../lib/seat.sh"
seat_main "$@"
