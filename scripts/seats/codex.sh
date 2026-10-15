#!/usr/bin/env bash
# codex seat: OpenAI Codex CLI, read-only sandbox. Contract: lib/seat.sh.
# Model from CODEX_MODEL when set, else the CLI's configured default.
# Effort xhigh: what makes an external seat worth its wall clock.
set -u
SEAT=codex

seat_gate() {
  command -v codex >/dev/null 2>&1 && return 0
  GATE_REASON="codex not on PATH"; return 1
}

seat_describe() { echo "${CODEX_MODEL:-default model}, xhigh, read-only sandbox"; }

seat_invoke() {
  # -s read-only: an explicit sandbox, never a permissive config default.
  # --skip-git-repo-check: a detached review worktree may not be trusted.
  # stdin is /dev/null: codex exec reads stdin whenever it is not a terminal.
  codex exec --skip-git-repo-check -s read-only -C "$WORKTREE" \
    ${CODEX_MODEL:+-m "$CODEX_MODEL"} -c 'model_reasoning_effort="xhigh"' \
    -o "$OUT" "$PROMPT" >"$LOG" 2>&1
}

# shellcheck source=../lib/seat.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/seat.sh"
seat_main "$@"
