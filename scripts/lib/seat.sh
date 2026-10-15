# shellcheck shell=bash
# seat.sh: the uniform seat contract. Every scripts/seats/<seat>.sh sets
# SEAT, defines three functions, sources this file and calls seat_main "$@".
#
#   seat_gate      returns 0 when the seat can run; else sets GATE_REASON.
#   seat_describe  echoes "<model>, <sandbox>" for status lines.
#   seat_invoke    runs the CLI once: prompt text in $PROMPT, cwd is the
#                  worktree, report to $OUT, stderr and noise to $LOG.
#
# CONTRACT
#   <seat>.sh -w <worktree> -p <prompt-file> -o <report-file> -t <seconds>
#     Report on <report-file>, log beside it as <report-file minus .md>.log.
#     stdout: exactly one line, <seat>|<status>|<detail>
#       ok|<model, sandbox>        the CLI exited 0 (the launcher validates)
#       skipped|<reason>           gate failed, nothing ran
#       timeout|<bytes>            cap hit; bytes = report + log so far
#       did-not-report|<reason>    the CLI failed
#     Exit 0 whenever a status line was printed; 2 on a bad invocation.
#   <seat>.sh -c
#     Discovery: <seat>|available|<model, sandbox> (exit 0) or
#     <seat>|disabled|<reason> (exit 1). Runs nothing but the gate.
#
# Every CLI flag lives in the seat script. No approval bypass flags, no
# passthrough: nothing from the invocation reaches the CLI except the
# worktree path, the prompt text and the output path.

SEAT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SEAT_LIB_DIR/common.sh"

seat_die() { echo "$SEAT.sh: $*" >&2; exit 2; }

seat_main() {
  WORKTREE="" PROMPT_FILE="" OUT="" CAP="" CHECK=0 GATE_REASON=""
  while getopts "w:p:o:t:ch" opt; do
    case "$opt" in
      w) WORKTREE=$OPTARG ;;
      p) PROMPT_FILE=$OPTARG ;;
      o) OUT=$OPTARG ;;
      t) CAP=$OPTARG ;;
      c) CHECK=1 ;;
      h) sed -n '2,30p' "$SEAT_LIB_DIR/seat.sh"; exit 0 ;;
      *) seat_die "unknown flag; run with -h" ;;
    esac
  done

  if [ "$CHECK" -eq 1 ]; then
    if seat_gate; then echo "$SEAT|available|$(seat_describe)"; exit 0; fi
    echo "$SEAT|disabled|$GATE_REASON"; exit 1
  fi

  [ -n "$WORKTREE" ] && [ -n "$PROMPT_FILE" ] && [ -n "$OUT" ] && [ -n "$CAP" ] \
    || seat_die "need -w <worktree> -p <prompt-file> -o <report-file> -t <seconds>"
  case "$CAP" in *[!0-9]*|"") seat_die "-t takes seconds (integer)";; esac
  [ -d "$WORKTREE" ] || seat_die "worktree is not a directory: $WORKTREE"
  [ -f "$PROMPT_FILE" ] || seat_die "prompt file not found: $PROMPT_FILE"
  OUTDIR=$(dirname "$OUT")
  mkdir -p "$OUTDIR" || seat_die "cannot create $OUTDIR"
  # Absolute paths now: the CLI runs from inside the worktree, and a relative
  # -o would write the report into the reviewed tree.
  OUTDIR=$(cd "$OUTDIR" && pwd)
  OUT="$OUTDIR/$(basename "$OUT")"
  LOG="${OUT%.md}.log"
  WORKTREE=$(cd "$WORKTREE" && pwd)
  PROMPT=$(cat "$PROMPT_FILE") || seat_die "cannot read $PROMPT_FILE"
  [ -n "$PROMPT" ] || seat_die "prompt file is empty: $PROMPT_FILE"

  if ! seat_gate; then echo "$SEAT|skipped|$GATE_REASON"; exit 0; fi

  : >"$OUT"; : >"$LOG"
  cd "$WORKTREE" || seat_die "cannot enter $WORKTREE"
  rc_run_capped "$CAP" seat_invoke </dev/null
  rc=$?
  if [ "$rc" -eq 124 ]; then
    echo "$SEAT|timeout|$(( $(rc_bytes "$OUT") + $(rc_bytes "$LOG") ))"
  elif [ "$rc" -eq 0 ]; then
    echo "$SEAT|ok|$(seat_describe)"
  else
    echo "$SEAT|did-not-report|exit $rc (see $(basename "$LOG"))"
  fi
  exit 0
}
