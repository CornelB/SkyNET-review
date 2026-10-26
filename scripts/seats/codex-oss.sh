#!/usr/bin/env bash
# codex-oss seat: Codex CLI driving a local ollama model, read-only sandbox.
# Contract: lib/seat.sh. Gate: codex AND ollama on PATH AND
# OLLAMA_REVIEWER_MODEL set AND, when the launcher names the run's diff in
# RC_DIFF_FILE, the diff fits the model's context. The launcher runs this
# seat's four lenses one at a time: a local model serves one request well,
# four badly.
set -u
SEAT=codex-oss

# The context ollama serves the model with: its num_ctx parameter, else
# OLLAMA_CONTEXT_LENGTH, else ollama's 4096; never above the model's trained
# context length. Empty when ollama cannot show the model.
ollama_ctx() {
  info=$(ollama show "$OLLAMA_REVIEWER_MODEL" 2>/dev/null) || return 0
  max=$(printf '%s\n' "$info" | awk '$1 == "context" && $2 == "length" { print $3; exit }')
  ctx=$(printf '%s\n' "$info" | awk '$1 == "num_ctx" { print $2; exit }')
  ctx=${ctx:-${OLLAMA_CONTEXT_LENGTH:-4096}}
  case "$ctx" in *[!0-9]*|"") return 0;; esac
  case "$max" in *[!0-9]*|"") ;; *) [ "$ctx" -gt "$max" ] && ctx=$max ;; esac
  echo "$ctx"
}

seat_gate() {
  command -v codex >/dev/null 2>&1 || { GATE_REASON="codex not on PATH"; return 1; }
  command -v ollama >/dev/null 2>&1 || { GATE_REASON="ollama not on PATH"; return 1; }
  [ -n "${OLLAMA_REVIEWER_MODEL:-}" ] || { GATE_REASON="OLLAMA_REVIEWER_MODEL not set"; return 1; }
  [ -f "${RC_DIFF_FILE:-}" ] || return 0
  ctx=$(ollama_ctx); [ -n "$ctx" ] || return 0
  # About 4 bytes per token.
  tokens=$(( ($(rc_bytes "$RC_DIFF_FILE") + 3) / 4 ))
  [ "$tokens" -le "$ctx" ] \
    || { GATE_REASON="diff ~$tokens tokens exceeds $OLLAMA_REVIEWER_MODEL context of $ctx"; return 1; }
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
