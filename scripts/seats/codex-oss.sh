#!/usr/bin/env bash
# codex-oss seat: Codex CLI driving a local ollama model, read-only sandbox.
# Contract: lib/seat.sh. Gate: codex AND ollama on PATH AND
# OLLAMA_REVIEWER_MODEL set AND OLLAMA_SELECTOR (when set) names a server
# that serves the model AND, when the launcher names the run's diff in
# RC_DIFF_FILE, the diff fits the model's context. The launcher runs this
# seat's four lenses one at a time: a local model serves one request well,
# four badly.
set -u
SEAT=codex-oss

# The context ollama serves the model with: its num_ctx parameter, else
# OLLAMA_CONTEXT_LENGTH, else $1 (default 4096, ollama's smallest default);
# never above the model's trained context length. Empty when ollama cannot
# show the model, or when no value is stated and $1 is "".
ollama_ctx() {
  info=$(ollama show "$OLLAMA_REVIEWER_MODEL" 2>/dev/null) || return 0
  max=$(printf '%s\n' "$info" | awk '$1 == "context" && $2 == "length" { print $3; exit }')
  ctx=$(printf '%s\n' "$info" | awk '$1 == "num_ctx" { print $2; exit }')
  ctx=${ctx:-${OLLAMA_CONTEXT_LENGTH:-${1-4096}}}
  case "$ctx" in *[!0-9]*|"") return 0;; esac
  case "$max" in *[!0-9]*|"") ;; *) [ "$ctx" -gt "$max" ] && ctx=$max ;; esac
  echo "$ctx"
}

# One line of selector output fit for a status line and status.json: control
# characters removed, "|" (the status line separator) turned into "/", the
# last non-empty line, at most 300 characters.
ollama_reason() {
  printf '%s\n' "$1" | tr -d '\000-\010\013-\037\177' | tr '|' '/' \
    | awk 'NF{l=$0} END{print substr(l, 1, 300)}'
}

# OLLAMA_SELECTOR names the Ollama server for this seat's model. Contract:
# SkyNET-agents docs/specs/2026-11-20-ollama-selector.md. Unset: nothing runs.
# A server: exports OLLAMA_HOST and CODEX_OSS_BASE_URL (codex reads only the
# latter) and RC_OLLAMA_URL. A refusal: GATE_REASON, return 1. stdout and
# stderr go to files, so a child the selector leaves behind cannot hold the
# gate.
ollama_select() {
  [ -n "${OLLAMA_SELECTOR:-}" ] || return 0
  case "$OLLAMA_SELECTOR" in /*) ;; *) GATE_REASON="OLLAMA_SELECTOR not executable"; return 1 ;; esac
  [ -f "$OLLAMA_SELECTOR" ] && [ -x "$OLLAMA_SELECTOR" ] \
    || { GATE_REASON="OLLAMA_SELECTOR not executable"; return 1; }
  sel_out=$(mktemp) sel_err=$(mktemp)
  RC_CAP_SIGNAL=KILL rc_run_capped 10 "$OLLAMA_SELECTOR" review "$OLLAMA_REVIEWER_MODEL" </dev/null >"$sel_out" 2>"$sel_err"
  sel_rc=$?
  sel_line=$(head -n 1 "$sel_out" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  sel_stderr=$(cat "$sel_err")
  rm -f "$sel_out" "$sel_err"
  if [ "$sel_rc" -eq 124 ]; then GATE_REASON="selector timed out"; return 1; fi
  if [ "$sel_rc" -ne 0 ]; then
    # An exit code above 128 can be a plain exit (ssh exits 255): the stderr
    # line wins; only a silent one reads as a signal.
    GATE_REASON=$(ollama_reason "$sel_stderr")
    [ -n "$GATE_REASON" ] && return 1
    if [ "$sel_rc" -gt 128 ] && sel_sig=$(kill -l "$((sel_rc - 128))" 2>/dev/null); then
      GATE_REASON="selector killed by SIG${sel_sig#SIG}"
    else
      GATE_REASON="selector exit $sel_rc"
    fi
    return 1
  fi
  [ -n "$sel_line" ] || return 0
  printf '%s\n' "$sel_line" | grep -Eq '^(http://)?[A-Za-z0-9._-]+:[0-9]+/?$' \
    || { GATE_REASON=$(ollama_reason "selector printed $sel_line"); return 1; }
  sel_line=${sel_line#http://}; sel_line=${sel_line%/}
  RC_OLLAMA_URL="http://$sel_line"
  export OLLAMA_HOST="$RC_OLLAMA_URL" CODEX_OSS_BASE_URL="$RC_OLLAMA_URL/v1"
  ollama show "$OLLAMA_REVIEWER_MODEL" >/dev/null 2>&1 \
    || { GATE_REASON=$(ollama_reason "$OLLAMA_REVIEWER_MODEL not served by $RC_OLLAMA_URL"); return 1; }
  return 0
}

seat_gate() {
  command -v codex >/dev/null 2>&1 || { GATE_REASON="codex not on PATH"; return 1; }
  command -v ollama >/dev/null 2>&1 || { GATE_REASON="ollama not on PATH"; return 1; }
  [ -n "${OLLAMA_REVIEWER_MODEL:-}" ] || { GATE_REASON="OLLAMA_REVIEWER_MODEL not set"; return 1; }
  ollama_select || return 1
  [ -f "${RC_DIFF_FILE:-}" ] || return 0
  ctx=$(ollama_ctx); [ -n "$ctx" ] || return 0
  # About 4 bytes per token.
  tokens=$(( ($(rc_bytes "$RC_DIFF_FILE") + 3) / 4 ))
  [ "$tokens" -le "$ctx" ] \
    || { GATE_REASON="diff ~$tokens tokens exceeds $OLLAMA_REVIEWER_MODEL context of $ctx"; return 1; }
  return 0
}

seat_describe() { echo "ollama ${OLLAMA_REVIEWER_MODEL:-?}${RC_OLLAMA_URL:+ @ $RC_OLLAMA_URL}, read-only sandbox"; }

# model_provider=ollama: --oss alone leaves the turn on the openai provider,
# and codex 0.166 refuses it with modelProviderMismatch, even in an empty home.
# CODEX_HOME: an empty home in the run directory, so the operator's codex
# config, MCP servers, plugins, hooks, skills and AGENTS.md do not reach the
# local model, which then calls tools that do not exist.
# Context: codex assumes 272k for a model it does not know and never compacts
# before ollama rejects the request. With a stated served context W it gets W
# and compacts at 3/4 of it: codex's own 9/10 leaves too little room for a
# step's tool outputs plus the compaction request. A guessed W is not passed.
seat_invoke() {
  home="$(dirname "$OUTDIR")/codex-oss-home"
  mkdir -p "$home" || return 1
  set --
  ctx=$(ollama_ctx "")
  [ -n "$ctx" ] && set -- -c "model_context_window=$ctx" -c "model_auto_compact_token_limit=$(( ctx * 3 / 4 ))"
  CODEX_HOME="$home" codex exec --oss --local-provider ollama -c model_provider=ollama "$@" \
    -m "$OLLAMA_REVIEWER_MODEL" -s read-only --skip-git-repo-check -C "$WORKTREE" \
    -o "$OUT" "$PROMPT" >"$LOG" 2>&1
}

# shellcheck source=../lib/seat.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/seat.sh"
seat_main "$@"
