#!/usr/bin/env bash
# run-tribunal.sh: launcher for review-board's tribunal mode. Every
# available seat runs every lens prompt in the run's worktree: 4 x N
# processes, blind to each other.
#
# USAGE
#   run-tribunal.sh discover [-s seat,seat]
#     One line per seat: <seat>|available|<model, sandbox> or
#     <seat>|disabled|<reason>. Runs only the gates.
#
#   run-tribunal.sh start [-s seat,seat] [-m model] [-e effort] <run-dir>
#     Discovers seats, aborts loudly (exit 3) when none is available, else
#     launches `run` detached in its own session and returns at once with
#     `started|<pid>|<run-dir>`. When the codex seat is available it first
#     prints `codex-model|<model>|<effort>|<usage note>`: the codex rule,
#     applied once for the whole run. The tribunal survives the session that
#     started it; everything already written stays on disk.
#
#   run-tribunal.sh run [-s seat,seat] [-m model] [-e effort] <run-dir>
#     The worker, in the foreground. `start` runs this.
#
#   run-tribunal.sh wait <run-dir>
#     Blocks until the run leaves the running state, then prints one
#     <lens>|<seat>|<status>|<detail> line per cell. Run it as a background
#     shell command to be notified when the tribunal ends.
#
#   run-tribunal.sh cancel <run-dir>
#     Kills the worker and every seat process, marks the run cancelled, and
#     removes the PR worktree.
#
#   -s  restrict to these seats (comma-separated; default all available)
#   -m  claude-cli model, -e claude-cli effort: the Claude model rule the
#       orchestrator applied (default Fable medium: the weekly Fable usage
#       that downgrades it is measured by the session, not here)
#   The codex seat's model and effort follow rc_codex_rule (lib/common.sh),
#   from the weekly Codex usage that lib/codex-usage.py reads (ai-usage skill, then codex).
#   RC_CAP_SECONDS  pins the per-process cap instead of sizing it
#
# MATRIX
#   reports/<lens>.<seat>.md    report      reports/<lens>.<seat>.log  log
#   reports/<lens>.<seat>.status  final line: <lens>|<seat>|<status>|<detail>
#   All seats start at once except codex-oss, whose four lenses run one at
#   a time. Cap per process from changed lines: 600 s up to 2000, 1200 s up
#   to 6000, 1800 s beyond. A timeout with nonzero bytes gets one retry at
#   twice the cap; at most one retry per seat. Each report is validated
#   (non-empty, verdict on line 1, no rejected-invocation text) before it
#   counts: status ok, or did-not-report with the reason.
#
# STATUS
#   status.json: id, target, mode, state (running | done | cancelled |
#   aborted | failed), pid, started, finished, cap, claude_model,
#   claude_effort, codex_model, codex_effort, codex_usage, seats, skipped, dead,
#   cells_total, cells_done, cells[]. Rewritten atomically as cells finish.
#
# No approval bypasses, no passthrough flags: every CLI flag lives in
# scripts/seats/<seat>.sh. Portable: Linux, macOS (bash 3.2), Git Bash.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
SEATS_DIR="$SCRIPT_DIR/seats"

die() { echo "run-tribunal.sh: $*" >&2; exit 2; }

CMD=${1:-}; [ -n "$CMD" ] && shift
case "$CMD" in -h|--help|help) sed -n '2,56p' "$0"; exit 0 ;; esac
ONLY="" CLAUDE_MODEL_ARG="" CLAUDE_EFFORT_ARG=""
while getopts "s:m:e:h" opt; do
  case "$opt" in
    s) ONLY=$(printf '%s' "$OPTARG" | tr ',' ' ') ;;
    m) CLAUDE_MODEL_ARG=$OPTARG ;;
    e) CLAUDE_EFFORT_ARG=$OPTARG ;;
    h) sed -n '2,56p' "$0"; exit 0 ;;
    *) die "unknown flag; run with -h" ;;
  esac
done
shift $((OPTIND - 1))
RUN_DIR=${1:-}
# Validate -s here, in the main shell: a die inside $(...) would only end
# the subshell.
for s in $ONLY; do
  case " $RC_SEATS " in *" $s "*) ;; *) die "unknown seat: $s (valid: $RC_SEATS)";; esac
done

# Seats asked for, in canonical order.
requested_seats() {
  if [ -z "$ONLY" ]; then echo "$RC_SEATS"; return; fi
  out=""
  for s in $RC_SEATS; do
    case " $ONLY " in *" $s "*) out="$out $s";; esac
  done
  echo "$out"
}

# The codex rule, once per run, exported so every codex cell and status line
# uses the same model. Only when the codex seat is asked for and installed.
pick_codex() {
  [ -z "${RC_CODEX_MODEL:-}" ] || return 0
  case " $(requested_seats) " in *" codex "*) ;; *) return 0;; esac
  command -v codex >/dev/null 2>&1 || return 0
  IFS='|' read -r RC_CODEX_MODEL RC_CODEX_EFFORT RC_CODEX_USAGE <<EOF
$(rc_codex_pick)
EOF
  export RC_CODEX_MODEL RC_CODEX_EFFORT RC_CODEX_USAGE
}

discover() {
  for s in $(requested_seats); do
    bash "$SEATS_DIR/$s.sh" -c 2>/dev/null || true
  done
}

need_run_dir() {
  [ -n "$RUN_DIR" ] || die "need <run-dir>"
  [ -f "$RUN_DIR/run.json" ] || die "not a run directory (no run.json): $RUN_DIR"
  RUN_DIR=$(cd "$RUN_DIR" && pwd -P)
  # Seats whose model has a context limit gate on the diff size.
  RC_DIFF_FILE=$(rc_json_get "$RUN_DIR/run.json" diff); export RC_DIFF_FILE
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------- status ---
# Rebuilt from the per-cell status files, so concurrent cells never write the
# same file. Fields set by the worker: STATE, STARTED, FINISHED, CAP, SEATS,
# SKIPPED (seat|reason lines).
write_status() {
  total=0 done_n=0 cells="" dead=""
  for seat in $SEATS; do
    for lens in $RC_LENSES; do
      total=$((total + 1))
      f="$RUN_DIR/reports/$lens.$seat.status"
      if [ -f "$f" ]; then
        done_n=$((done_n + 1))
        IFS='|' read -r _l _s st detail <"$f"
        [ "$st" = ok ] || case " $dead " in *" $seat "*) ;; *) dead="$dead $seat";; esac
      else
        st=running detail=""
      fi
      cells="$cells${cells:+,}{\"lens\":\"$lens\",\"seat\":\"$seat\",\"status\":\"$st\",\"detail\":\"$(rc_json_str "$detail")\",\"report\":\"$(rc_json_str "$RUN_DIR/reports/$lens.$seat.md")\"}"
    done
  done
  seats_json="" ; for s in $SEATS; do seats_json="$seats_json${seats_json:+,}\"$s\""; done
  skipped_json=""
  while IFS='|' read -r s reason; do
    [ -n "$s" ] && skipped_json="$skipped_json${skipped_json:+,}\"$s\":\"$(rc_json_str "$reason")\""
  done <<EOF
$SKIPPED
EOF
  dead_json=""; for s in $dead; do dead_json="$dead_json${dead_json:+,}\"$s\""; done
  printf '{"id":"%s","target":"%s","mode":"tribunal","state":"%s","pid":%s,"started":"%s","finished":"%s","cap":%s,"claude_model":"%s","claude_effort":"%s","codex_model":"%s","codex_effort":"%s","codex_usage":"%s","seats":[%s],"skipped":{%s},"dead":[%s],"cells_total":%s,"cells_done":%s,"cells":[%s]}\n' \
    "$(rc_json_str "$(rc_json_get "$RUN_DIR/run.json" id)")" "$(rc_json_str "$(rc_json_get "$RUN_DIR/run.json" target)")" \
    "$STATE" "$$" "$STARTED" "$FINISHED" "$CAP" "$RC_CLAUDE_MODEL" "$RC_CLAUDE_EFFORT" \
    "${RC_CODEX_MODEL:-}" "${RC_CODEX_EFFORT:-}" "$(rc_json_str "${RC_CODEX_USAGE:-}")" \
    "$seats_json" "$skipped_json" "$dead_json" "$total" "$done_n" "$cells" >"$RUN_DIR/status.json.tmp"
  mv "$RUN_DIR/status.json.tmp" "$RUN_DIR/status.json"
}

# ------------------------------------------------------------------ cells ---
# One (lens, seat) process, with the one-retry rule. Writes the cell's final
# status file last, so its presence means the cell is done.
run_cell() { # $1=seat $2=lens
  seat=$1 lens=$2
  out="$RUN_DIR/reports/$lens.$seat.md" log="$RUN_DIR/reports/$lens.$seat.log"
  line=$(bash "$SEATS_DIR/$seat.sh" -w "$WORKTREE" -p "$RUN_DIR/prompts/$lens.md" -o "$out" -t "$CAP" 2>>"$log")
  status=$(printf '%s' "$line" | cut -d'|' -f2)
  detail=$(printf '%s' "$line" | cut -d'|' -f3-)
  if [ "$status" = timeout ] && [ "${detail:-0}" -gt 0 ] 2>/dev/null \
     && mkdir "$RUN_DIR/reports/.retry-$seat" 2>/dev/null; then
    raised=$((CAP * 2))
    echo "== retry at ${raised}s after timeout with ${detail} bytes ==" >>"$RUN_DIR/reports/$lens.$seat.retry.log"
    line=$(bash "$SEATS_DIR/$seat.sh" -w "$WORKTREE" -p "$RUN_DIR/prompts/$lens.md" -o "$out" -t "$raised" 2>>"$log")
    status=$(printf '%s' "$line" | cut -d'|' -f2)
    detail="$(printf '%s' "$line" | cut -d'|' -f3-) (retried at ${raised}s)"
  fi
  case "$status" in
    ok)
      v=$(rc_validate_report "$out" "$log")
      if [ "${v%%|*}" = ok ]; then final="ok|$detail"; else final="$v"; fi ;;
    timeout) final="timeout|${detail} bytes at cap" ;;
    skipped|did-not-report) final="$status|$detail" ;;
    *) final="did-not-report|seat script printed no status line (see $(basename "$log"))" ;;
  esac
  echo "$lens|$seat|$final" >"$RUN_DIR/reports/$lens.$seat.status"
}

# codex-oss: one local model, four lenses in sequence.
run_serial() { # $1=seat
  for lens in $RC_LENSES; do
    [ -f "$RUN_DIR/.cancelled" ] && return
    run_cell "$1" "$lens"
  done
}

worker() {
  need_run_dir
  WORKTREE=$(rc_json_get "$RUN_DIR/run.json" worktree)
  [ -d "$WORKTREE" ] || die "worktree missing: $WORKTREE"
  CHANGED=$(rc_json_get "$RUN_DIR/run.json" changed_lines); CHANGED=${CHANGED:-0}
  CAP=$(rc_cap_for_lines "$CHANGED")
  # RC_CAP_SECONDS pins the cap (tests, or an operator who knows better).
  case "${RC_CAP_SECONDS:-}" in ''|*[!0-9]*) ;; *) CAP=$RC_CAP_SECONDS ;; esac
  # shellcheck disable=SC2046
  set -- $(rc_model_rule tribunal)
  RC_CLAUDE_MODEL=${CLAUDE_MODEL_ARG:-$1}
  RC_CLAUDE_EFFORT=${CLAUDE_EFFORT_ARG:-$2}
  export RC_CLAUDE_MODEL RC_CLAUDE_EFFORT
  pick_codex
  STARTED=$(now) FINISHED="" STATE=running SEATS="" SKIPPED=""

  while IFS='|' read -r s st detail; do
    [ -n "$s" ] || continue
    if [ "$st" = available ]; then SEATS="$SEATS $s"; else SKIPPED="$SKIPPED$s|$detail
"; fi
  done <<EOF
$(discover)
EOF

  if [ -z "$SEATS" ]; then
    STATE=aborted FINISHED=$(now)
    write_status
    echo "run-tribunal.sh: zero seats available; nothing ran" >&2
    printf '%s' "$SKIPPED" | sed 's/^/  /' >&2
    exit 3
  fi

  echo "$$" >"$RUN_DIR/tribunal.pid"
  rm -f "$RUN_DIR/.cancelled" "$RUN_DIR"/reports/*.status
  rm -rf "$RUN_DIR"/reports/.retry-*
  write_status

  PIDS=""
  on_term() {
    : >"$RUN_DIR/.cancelled"
    for p in $PIDS; do rc_kill_tree "$p"; done
    STATE=cancelled FINISHED=$(now)
    write_status
    exit 130
  }
  trap on_term TERM INT

  for seat in $SEATS; do
    if [ "$seat" = codex-oss ]; then
      run_serial "$seat" & PIDS="$PIDS $!"
    else
      for lens in $RC_LENSES; do
        run_cell "$seat" "$lens" & PIDS="$PIDS $!"
      done
    fi
  done

  # Refresh status.json while cells finish.
  while :; do
    running=0
    for p in $PIDS; do kill -0 "$p" 2>/dev/null && running=1; done
    write_status
    [ "$running" -eq 0 ] && break
    sleep 5
  done
  wait 2>/dev/null
  STATE="done" FINISHED=$(now)
  write_status
  rm -f "$RUN_DIR/tribunal.pid"
  print_cells
}

print_cells() {
  for f in "$RUN_DIR"/reports/*.status; do
    [ -f "$f" ] && cat "$f"
  done
}

state_of() { rc_json_get "$RUN_DIR/status.json" state; }

case "$CMD" in
  discover)
    discover
    ;;
  run)
    worker
    ;;
  start)
    need_run_dir
    pick_codex
    # Fail loudly here, before anything is detached.
    if ! discover | grep -q '|available|'; then
      discover | sed 's/^/  /' >&2
      echo "run-tribunal.sh: zero seats available; nothing ran" >&2
      exit 3
    fi
    [ -n "${RC_CODEX_MODEL:-}" ] && echo "codex-model|$RC_CODEX_MODEL|$RC_CODEX_EFFORT|$RC_CODEX_USAGE"
    args=""
    [ -n "$ONLY" ] && args="-s $(printf '%s' "$ONLY" | tr ' ' ',')"
    : >"$RUN_DIR/tribunal.log"
    # shellcheck disable=SC2086
    if command -v setsid >/dev/null 2>&1; then
      setsid nohup bash "$0" run $args ${CLAUDE_MODEL_ARG:+-m "$CLAUDE_MODEL_ARG"} ${CLAUDE_EFFORT_ARG:+-e "$CLAUDE_EFFORT_ARG"} "$RUN_DIR" >>"$RUN_DIR/tribunal.log" 2>&1 </dev/null &
    else
      nohup bash "$0" run $args ${CLAUDE_MODEL_ARG:+-m "$CLAUDE_MODEL_ARG"} ${CLAUDE_EFFORT_ARG:+-e "$CLAUDE_EFFORT_ARG"} "$RUN_DIR" >>"$RUN_DIR/tribunal.log" 2>&1 </dev/null &
    fi
    pid=$!
    # Wait for the worker to claim the run, so a `wait` right after cannot
    # read the prepared state as finished.
    i=0; while [ "$(state_of)" = prepared ] && [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
    echo "started|$pid|$RUN_DIR"
    ;;
  wait)
    need_run_dir
    while [ "$(state_of)" = running ] || [ "$(state_of)" = prepared ]; do
      pid=$(cat "$RUN_DIR/tribunal.pid" 2>/dev/null)
      if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && [ "$(state_of)" = running ]; then
        echo "run-tribunal.sh: worker $pid died without finishing (see tribunal.log)" >&2
        exit 4
      fi
      sleep 5
    done
    echo "state|$(state_of)"
    print_cells
    ;;
  cancel)
    need_run_dir
    pid=$(cat "$RUN_DIR/tribunal.pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      # The worker runs in its own session: signal the whole process group,
      # then the worker itself in case setsid was unavailable.
      kill -TERM -- "-$pid" 2>/dev/null
      kill -TERM "$pid" 2>/dev/null
      i=0; while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
      echo "cancelled|$pid|$RUN_DIR"
    else
      echo "not-running|$(state_of)|$RUN_DIR"
    fi
    bash "$SCRIPT_DIR/prepare-run.sh" cleanup "$RUN_DIR"
    ;;
  *)
    die "usage: run-tribunal.sh discover | start | run | wait | cancel (run with -h)"
    ;;
esac
