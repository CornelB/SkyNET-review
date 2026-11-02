#!/usr/bin/env bash
# codex seat: OpenAI Codex CLI, read-only sandbox. Contract: lib/seat.sh.
# Model and effort follow the codex rule (rc_codex_rule): GPT-6 Astra at low
# effort, GPT-6.1 Sol at xhigh once the weekly Codex usage is above 60%. The
# launcher reads the usage once and passes what it applied in RC_CODEX_MODEL,
# RC_CODEX_EFFORT, RC_CODEX_USAGE and RC_CODEX_FULL; without them the seat
# reads it itself. A full 5h or weekly window disables the seat.
set -u
SEAT=codex

pick() {
  if [ -z "${RC_CODEX_MODEL:-}" ]; then
    IFS='|' read -r RC_CODEX_MODEL RC_CODEX_EFFORT RC_CODEX_USAGE RC_CODEX_FULL <<EOF
$(rc_codex_pick)
EOF
  fi
  case "$RC_CODEX_MODEL" in *[!a-z0-9.-]*|"") RC_CODEX_MODEL=gpt-6-astra;; esac
  case "${RC_CODEX_EFFORT:-}" in low|medium|high|xhigh|max) ;; *) RC_CODEX_EFFORT=low;; esac
}

seat_gate() {
  command -v codex >/dev/null 2>&1 || { GATE_REASON="codex not on PATH"; return 1; }
  pick
  [ -z "${RC_CODEX_FULL:-}" ] || { GATE_REASON="codex usage full: $RC_CODEX_FULL"; return 1; }
}

seat_describe() { echo "$RC_CODEX_MODEL, $RC_CODEX_EFFORT${RC_CODEX_USAGE:+, $RC_CODEX_USAGE}, read-only sandbox"; }

seat_invoke() {
  # -s read-only: an explicit sandbox, never a permissive config default.
  # --skip-git-repo-check: a detached review worktree may not be trusted.
  # stdin is /dev/null: codex exec reads stdin whenever it is not a terminal.
  codex exec --skip-git-repo-check -s read-only -C "$WORKTREE" \
    -m "$RC_CODEX_MODEL" -c "model_reasoning_effort=\"$RC_CODEX_EFFORT\"" \
    -o "$OUT" "$PROMPT" >"$LOG" 2>&1
}

# shellcheck source=../lib/seat.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/seat.sh"
seat_main "$@"
