# shellcheck shell=bash
# common.sh: helpers shared by the launcher, the run preparer, the seats and
# the result listing. Sourced, never executed. Portable: Linux, macOS (bash
# 3.2, no associative arrays), Git Bash (no GNU timeout).

# Lens order is the report's priority order.
# shellcheck disable=SC2034 # read by every script that sources this file
RC_LENSES="simplicity functionality security maintainability"
# Every seat that has a script under scripts/seats/.
# shellcheck disable=SC2034
RC_SEATS="codex antigravity grok claude-cli kimi-cli cursor-cli codex-oss"

# Lines added or removed in a unified diff, headers excluded. A removed line
# whose text starts with "-- " shows as "--- " and must still count, so file
# headers are recognized by position (between "diff --git" and the first
# "@@"), not by prefix.
rc_changed_lines() { # $1=diff file
  [ -f "$1" ] || { echo 0; return; }
  awk '/^diff --git /{h=1; next} /^@@/{h=0; next} h{next} /^[+-]/{n++} END{print n+0}' "$1"
}

# Wall-clock cap per seat process, from changed lines.
rc_cap_for_lines() { # $1=changed lines
  if [ "$1" -le 2000 ]; then echo 600
  elif [ "$1" -le 6000 ]; then echo 1200
  else echo 1800
  fi
}

# Lens model rule, before any usage downgrade: "<model> <effort>".
rc_model_rule() { # $1=changed lines
  if [ "$1" -lt 100 ]; then echo "opus xhigh"; else echo "fable medium"; fi
}

# Escape a value for a JSON string body.
rc_json_str() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' | awk 'BEGIN{ORS=""} NR>1{print "\\n"} {print}'
}

# Read one top-level scalar from a flat JSON object file. jq when present;
# otherwise a sed scan good enough for the files this plugin writes itself.
rc_json_get() { # $1=file $2=key
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$2" '.[$k] // empty | tostring' "$1" 2>/dev/null
  else
    sed -nE 's/.*"'"$2"'":("([^"\\]*(\\.[^"\\]*)*)"|(-?[0-9]+|true|false)).*/\2\4/p' "$1" | head -n 1
  fi
}

rc_bytes() { b=$( { wc -c <"$1"; } 2>/dev/null | tr -cd '0-9'); echo "${b:-0}"; }

# Kill a process and every descendant. A seat runs its CLI inside a function,
# a pipeline or a namespace wrapper, so killing only the direct child would
# leave the CLI running.
rc_kill_tree() { # $1=pid
  for c in $(pgrep -P "$1" 2>/dev/null); do rc_kill_tree "$c"; done
  kill "$1" 2>/dev/null
}

# Run "$@" with a wall-clock cap. Exit 124 on cap. No GNU timeout needed.
# The watchdog leaves a marker before it kills, so a CLI that traps SIGTERM
# and exits 1 still reads as a timeout.
rc_run_capped() { # $1=seconds, rest=command
  rc_secs=$1; shift
  rc_flag="${TMPDIR:-/tmp}/rc-cap.$$.$RANDOM"
  rm -f "$rc_flag"
  "$@" & rc_cpid=$!
  ( i=0; while [ "$i" -lt "$rc_secs" ]; do sleep 1; kill -0 "$rc_cpid" 2>/dev/null || exit 0; i=$((i + 1)); done
    : >"$rc_flag"; rc_kill_tree "$rc_cpid" ) & rc_wpid=$!
  wait "$rc_cpid" 2>/dev/null; rc_rc=$?
  rc_kill_tree "$rc_wpid"; wait "$rc_wpid" 2>/dev/null
  if [ -e "$rc_flag" ]; then rm -f "$rc_flag"; return 124; fi
  return "$rc_rc"
}

# Report validation. Exit codes lie: a rejected flag can still exit 0 and
# land on stdout, that is, in the report file. Echoes "ok|<file>" or
# "did-not-report|<reason>".
rc_validate_report() { # $1=report $2=log
  out=$1 log=$2
  head3=$( { head -n 3 "$out"; head -n 3 "$log"; } 2>/dev/null )
  if grep -qiE 'auto-denied|permission request (was )?denied|no output produced' "$out" "$log" 2>/dev/null; then
    echo "did-not-report|tool permission denial (see $(basename "$log"))"
  elif printf '%s\n' "$head3" | grep -qiE 'usage( of|:)|unknown (flag|option|effort level)|unrecognized (option|argument)|invalid model selection|not supported in the selected location|cannot combine'; then
    echo "did-not-report|CLI rejected the invocation (see $(basename "$log"))"
  elif grep -qiE 'usage limit|quota exceeded|out of (credits|quota)|not authenticated|invalid api key' "$log" 2>/dev/null; then
    # Log only: a security review legitimately discusses rate limits and
    # credentials and must not be discarded for saying so.
    echo "did-not-report|quota or auth limit (see $(basename "$log"))"
  elif [ ! -s "$out" ]; then
    echo "did-not-report|empty report (see $(basename "$log"))"
  elif ! awk 'NF{print; exit}' "$out" | tr -d '*#`>_' | grep -qiE '^[[:space:]]*verdict[[:space:]]*:'; then
    echo "did-not-report|no verdict on line 1 (see $(basename "$out"))"
  else
    echo "ok|$out"
  fi
}

# Default root for run directories.
rc_runs_root() {
  r=${CLAUDE_SCRATCHPAD:-${TMPDIR:-/tmp}}
  echo "${r%/}/review-council"
}

# Index of every run directory ever prepared, newest last. Lets
# /review-council:result find runs made from other sessions or --run-dir.
rc_index_file() {
  echo "${XDG_STATE_HOME:-$HOME/.local/state}/review-council/runs.txt"
}
