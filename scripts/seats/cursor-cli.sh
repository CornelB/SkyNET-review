#!/usr/bin/env bash
# cursor-cli seat: Cursor agent CLI, headless, ask mode. Contract: lib/seat.sh.
set -u
SEAT=cursor-cli

seat_gate() {
  # cursor-agent, not the bare `agent` the installer also links: grok ships
  # an `agent` too, so that name proves nothing.
  command -v cursor-agent >/dev/null 2>&1 && return 0
  GATE_REASON="cursor-agent not on PATH"; return 1
}

seat_describe() { echo "${CURSOR_CLI_MODEL:-default model}, ask mode (read-only)"; }

seat_invoke() {
  # --mode ask: read-only. A bare -p has write and shell tools.
  # --trust: trusts the review worktree so a headless run does not stop at
  #   the workspace-trust question. It approves no tool. --force is never passed.
  # Prompt on stdin, as a bare -p reads it.
  printf '%s' "$PROMPT" | cursor-agent -p --output-format text --mode ask --trust \
    ${CURSOR_CLI_MODEL:+--model "$CURSOR_CLI_MODEL"} >"$OUT" 2>"$LOG"
}

# shellcheck source=../lib/seat.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/seat.sh"
seat_main "$@"
