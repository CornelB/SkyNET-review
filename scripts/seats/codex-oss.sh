#!/usr/bin/env bash
# codex-oss seat: Codex CLI driving a local ollama model, read-only sandbox.
# Contract: lib/seat.sh. Gate: codex AND ollama on PATH AND
# OLLAMA_REVIEWER_MODEL set. The launcher runs this seat's four lenses one at
# a time: a local model serves one request well, four badly.
set -u
SEAT=codex-oss

seat_gate() {
  command -v codex >/dev/null 2>&1 || { GATE_REASON="codex not on PATH"; return 1; }
  command -v ollama >/dev/null 2>&1 || { GATE_REASON="ollama not on PATH"; return 1; }
  [ -n "${OLLAMA_REVIEWER_MODEL:-}" ] || { GATE_REASON="OLLAMA_REVIEWER_MODEL not set"; return 1; }
  return 0
}

seat_describe() { echo "ollama ${OLLAMA_REVIEWER_MODEL:-?}, read-only sandbox"; }

seat_invoke() {
  codex exec --oss --local-provider ollama -m "$OLLAMA_REVIEWER_MODEL" \
    -s read-only --skip-git-repo-check -C "$WORKTREE" \
    -o "$OUT" "$PROMPT" >"$LOG" 2>&1
}

# shellcheck source=../lib/seat.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/seat.sh"
seat_main "$@"
