#!/usr/bin/env bash
# runs.sh: list, show and cancel review-board runs, for /review-board:result.
#
# USAGE
#   runs.sh list
#     One line per run, newest first:
#       <id>|<target>|<mode>|<state>|<done>/<total>|<run-dir>
#     Runs come from the run index ($XDG_STATE_HOME/review-board/runs.txt,
#     default ~/.local/state/...) plus every run directory under the default
#     root; missing directories are skipped.
#   runs.sh show <run-id|run-dir>
#     Finished run with a report: report|<path>.
#     Otherwise: state|<state>|<done>/<total>, then one line per process so
#     far: <lens>|<seat>|<status>|<detail>|<report-path>.
#   runs.sh cancel <run-id|run-dir>
#     Cancels a running tribunal through run-tribunal.sh cancel.
#
# Read-only except cancel. Exit 1 when the run cannot be found.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

die() { echo "runs.sh: $*" >&2; exit 1; }

# Every known run directory, oldest first, deduplicated.
all_runs() {
  {
    [ -f "$(rc_index_file)" ] && cat "$(rc_index_file)"
    for d in "$(rc_runs_root)"/review-*; do [ -d "$d" ] && echo "$d"; done
  } | while IFS= read -r d; do
    # Physical paths, as prepare-run.sh records them, so one run reached
    # through a symlinked root (macOS /var) is listed once.
    [ -f "$d/run.json" ] && (cd "$d" && pwd -P)
  done | awk 'NF && !seen[$0]++'
}

resolve() { # $1=id or dir
  if [ -f "$1/run.json" ]; then (cd "$1" && pwd -P); return; fi
  found=""
  while IFS= read -r d; do
    [ "$(basename "$d")" = "$1" ] && found=$d
  done <<EOF
$(all_runs)
EOF
  [ -n "$found" ] || die "no run with id $1"
  echo "$found"
}

# State and progress. Local runs have no worker: they read as done once
# report.md exists, and count lens reports saved by the orchestrator.
progress() { # $1=run dir; echoes "<state>|<done>/<total>"
  d=$1
  mode=$(rc_json_get "$d/status.json" mode)
  state=$(rc_json_get "$d/status.json" state)
  if [ "$mode" = tribunal ]; then
    done_n=$(rc_json_get "$d/status.json" cells_done)
    total=$(rc_json_get "$d/status.json" cells_total)
    pid=$(cat "$d/tribunal.pid" 2>/dev/null)
    if [ "$state" = running ] && { [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; }; then state=failed; fi
  else
    done_n=0 total=4
    for f in "$d"/reports/*.local.md; do [ -f "$f" ] && done_n=$((done_n + 1)); done
    [ "$state" = prepared ] && state=running
  fi
  [ -f "$d/report.md" ] && state="done"
  echo "${state:-unknown}|${done_n:-0}/${total:-0}"
}

case "${1:-list}" in
  list)
    all_runs | awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}' | while IFS= read -r d; do
      echo "$(rc_json_get "$d/run.json" id)|$(rc_json_get "$d/run.json" target)|$(rc_json_get "$d/status.json" mode)|$(progress "$d")|$d"
    done
    ;;
  show)
    [ -n "${2:-}" ] || die "usage: runs.sh show <run-id>"
    d=$(resolve "$2") || exit 1
    if [ -f "$d/report.md" ]; then echo "report|$d/report.md"; exit 0; fi
    echo "state|$(progress "$d")"
    for f in "$d"/reports/*.status; do
      [ -f "$f" ] || continue
      IFS='|' read -r lens seat st detail <"$f"
      echo "$lens|$seat|$st|$detail|$d/reports/$lens.$seat.md"
    done
    for f in "$d"/reports/*.local.md; do
      [ -f "$f" ] || continue
      lens=$(basename "$f" .local.md)
      echo "$lens|local|ok||$f"
    done
    ;;
  cancel)
    [ -n "${2:-}" ] || die "usage: runs.sh cancel <run-id>"
    d=$(resolve "$2") || exit 1
    [ "$(rc_json_get "$d/status.json" mode)" = tribunal ] || die "only a tribunal runs in the background; $2 is a local run"
    bash "$SCRIPT_DIR/run-tribunal.sh" cancel "$d"
    ;;
  *)
    die "usage: runs.sh list | show <run-id> | cancel <run-id>"
    ;;
esac
