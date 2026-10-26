#!/usr/bin/env bash
# claude-cli seat: a blind headless Claude Code session. Contract: lib/seat.sh.
# Model and effort follow the Claude model rule for the tribunal; the launcher
# passes the values it applied in RC_CLAUDE_MODEL and RC_CLAUDE_EFFORT
# (default fable, medium).
#
# A model the account cannot use answers "API Error: 400" at once (Fable
# without data retention). The lens then reruns on opus xhigh, the model
# rule's own fallback, and the status line names the switch; the seat does
# not drop out of the tribunal.
set -u
SEAT=claude-cli

model() { m=${RC_CLAUDE_MODEL:-fable}; case "$m" in *[!a-z0-9.-]*|"") m=fable;; esac; echo "$m"; }
effort() { e=${RC_CLAUDE_EFFORT:-medium}; case "$e" in low|medium|high|xhigh|max) ;; *) e=medium;; esac; echo "$e"; }

seat_gate() {
  command -v claude >/dev/null 2>&1 || { GATE_REASON="claude not on PATH"; return 1; }
  # An unauthenticated -p run can exit 0 with a non-report on stdout.
  claude auth status >/dev/null 2>&1 || { GATE_REASON="claude not authenticated (claude auth login)"; return 1; }
  return 0
}

seat_describe() {
  if [ -f "${OUT%.md}.fallback" ]; then
    echo "opus, xhigh ($(model) rejected: API Error 400), plan mode, read-only tools"
  else
    echo "$(model), $(effort), plan mode, read-only tools"
  fi
}

claude_run() { # $1=model $2=effort
  # --permission-mode plan: read-only auto-approval, no edits, no shell.
  # --tools: only the read tools exist in the session.
  # --setting-sources "" and --safe-mode: no settings, CLAUDE.md, skills,
  #   plugins, hooks or MCP servers; the seat is blind to the operator's setup.
  # --no-session-persistence: nothing lands in the operator's history.
  # Prompt on stdin: a bare -p reads it there, and --tools is variadic.
  printf '%s' "$PROMPT" | claude -p --permission-mode plan --setting-sources "" \
    --safe-mode --no-session-persistence --tools "Read,Grep,Glob" \
    --model "$1" --effort "$2" >"$OUT" 2>>"$LOG"
}

# Runs in the capped background job, so the fallback is recorded in a file
# for seat_describe, not in a variable.
seat_invoke() {
  rm -f "${OUT%.md}.fallback"
  claude_run "$(model)" "$(effort)"
  rc=$?
  [ "$(model)" != opus ] && grep -qs 'API Error: 400' "$OUT" "$LOG" || return "$rc"
  { echo "== $(model) rejected:"; cat "$OUT"; echo "== retrying on opus xhigh =="; } >>"$LOG"
  : >"${OUT%.md}.fallback"
  claude_run opus xhigh
}

# shellcheck source=../lib/seat.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/seat.sh"
seat_main "$@"
