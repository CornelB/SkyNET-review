#!/usr/bin/env bash
# claude-cli seat: a blind headless Claude Code session. Contract: lib/seat.sh.
# Model and effort follow the local lens rule; the launcher passes the values
# it applied in RC_CLAUDE_MODEL and RC_CLAUDE_EFFORT (default opus, xhigh).
set -u
SEAT=claude-cli

model() { m=${RC_CLAUDE_MODEL:-opus}; case "$m" in *[!a-z0-9.-]*|"") m=opus;; esac; echo "$m"; }
effort() { e=${RC_CLAUDE_EFFORT:-xhigh}; case "$e" in low|medium|high|xhigh|max) ;; *) e=xhigh;; esac; echo "$e"; }

seat_gate() {
  command -v claude >/dev/null 2>&1 || { GATE_REASON="claude not on PATH"; return 1; }
  # An unauthenticated -p run can exit 0 with a non-report on stdout.
  claude auth status >/dev/null 2>&1 || { GATE_REASON="claude not authenticated (claude auth login)"; return 1; }
  return 0
}

seat_describe() { echo "$(model), $(effort), plan mode, read-only tools"; }

seat_invoke() {
  # --permission-mode plan: read-only auto-approval, no edits, no shell.
  # --tools: only the read tools exist in the session.
  # --setting-sources "" and --safe-mode: no settings, CLAUDE.md, skills,
  #   plugins, hooks or MCP servers; the seat is blind to the operator's setup.
  # --no-session-persistence: nothing lands in the operator's history.
  # Prompt on stdin: a bare -p reads it there, and --tools is variadic.
  printf '%s' "$PROMPT" | claude -p --permission-mode plan --setting-sources "" \
    --safe-mode --no-session-persistence --tools "Read,Grep,Glob" \
    --model "$(model)" --effort "$(effort)" >"$OUT" 2>"$LOG"
}

# shellcheck source=../lib/seat.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/seat.sh"
seat_main "$@"
