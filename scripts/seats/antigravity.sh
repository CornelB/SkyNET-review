#!/usr/bin/env bash
# antigravity seat: agy CLI, --sandbox, no --mode, no shell. Contract:
# lib/seat.sh. No gemini-cli fallback.
#
# PERMISSIONS. The seat's own agy-settings.json, passed with --settings,
# replaces the permissions of ~/.gemini/antigravity-cli/settings.json for this
# run only; model and project still come from the user's file. The user's file
# is never read for permissions and never written.
#   - Allow read_file(*) only. It lets the seat read any file the user can,
#     because the worktree path is per-run.
#   - Deny write_file, command, read_url, mcp and unsandboxed. A denied call
#     fails and the run goes on; a call with no rule at all ends a headless
#     run with no output. Leaving write_file out is NOT enough: agy's "auto"
#     agent mode approves file edits that no rule names.
#   - No command rule can be scoped: agy matches it against the full command
#     string. command(*) would be blanket shell approval on an untrusted tree.
#   - --sandbox: the shell (were it ever allowed) is read-only and has no
#     network.
#   - search_web has no permission class and no setting turns it off. It is
#     the one remaining way out: a query string reaches Google.
#   - No `--mode plan`: plan mode stops and waits for a Proceed click, so the
#     seat writes a plan file and never reviews.
#
# MODEL. Highest-ranked slug from `agy models`: argon first (high, then
# medium; low is never used), then the flash family (newest version, high
# effort), pro only as the fallback floor. Argon is not on every plan. Effort
# is baked into the slug. Candidates are tried in order because a listed model
# can still be unavailable to the account; each such failure is immediate. The
# slug that last produced a valid report is cached in
# $XDG_CACHE_HOME/review-board/agy-model together with the candidate list it
# was picked from, and tried first only while that list is unchanged, so a
# newly listed model gets its turn.
set -u
SEAT=antigravity

AGY_SETTINGS="$(cd "$(dirname "$0")" && pwd)/agy-settings.json"
AGY_FALLBACK="gemini-4-argon-high gemini-4-argon-medium gemini-3.8-flash-high gemini-3.1-pro-high"
AGY_MODEL_ERR='invalid model selection|not recognized as a known model|not supported in the selected location|required the "command" permission'
AGY_MODEL_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/review-board/agy-model"
AGY_NOSHELL="HARD CONSTRAINT: you have NO shell access. Every shell command is denied. Read the diff file and every source file ONLY with your native file-reading tool, and ONLY by the absolute paths given in this prompt: a relative path does not resolve without a shell. If you cannot read a file, say so; reporting a value you did not read is a failed review."
NL='
'

# Ordered model candidates: argon (high, medium) before flash before pro,
# newer first, higher effort first.
agy_candidates() {
  command -v perl >/dev/null 2>&1 || return 0
  agy models 2>/dev/null | perl -ne '
    BEGIN { @m = (); %rank = (high => 0, medium => 1, low => 2); %tier = (argon => 0, flash => 1, pro => 2) }
    next unless /^(gemini-([0-9]+(?:\.[0-9]+)?)-(argon|pro|flash)-(high|medium|low))\b/;
    my ($slug, $ver, $tier, $eff) = ($1, $2, $3, $4);
    next if $tier eq "argon" && $eff eq "low";
    my @p = split /\./, $ver;
    push @m, [ $tier{$tier}, -($p[0] * 1000 + ($p[1] // 0)), $rank{$eff}, $slug ];
    END {
      @m = sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] || $a->[2] <=> $b->[2] } @m;
      print join(" ", map { $_->[3] } @m);
    }
  ' 2>/dev/null
}

seat_gate() {
  command -v agy >/dev/null 2>&1 || { GATE_REASON="agy not on PATH"; return 1; }
  return 0
}

seat_describe() {
  used=$(cat "${OUT%.md}.model" 2>/dev/null)
  echo "${used:-best argon or flash slug}, --sandbox, read_file only (agy-settings.json)"
}

# Walk the candidates past model-selection errors. Each attempt overwrites the
# log so a rejected candidate's message cannot condemn a later good report;
# the whole trail is kept aside and restored only when every candidate fails.
seat_invoke() {
  attempts="${OUT%.md}.attempts.log"
  : >"$attempts"
  models=$(agy_candidates)
  [ -n "$models" ] || models=$AGY_FALLBACK
  all=$models
  # Line 1: the slug; line 2: the candidate list it was picked from.
  cached=""
  if [ -f "$AGY_MODEL_CACHE" ] && [ "$(sed -n 2p "$AGY_MODEL_CACHE")" = "$models" ]; then
    cached=$(sed -n 1p "$AGY_MODEL_CACHE" | tr -cd 'a-zA-Z0-9.-')
  fi
  if [ -n "$cached" ]; then
    rest=""; for m in $models; do [ "$m" = "$cached" ] || rest="$rest $m"; done
    models="$cached$rest"
  fi
  for m in $models; do
    echo "== agy model $m ==" >>"$attempts"
    agy --sandbox --settings "$AGY_SETTINGS" --model "$m" --print-timeout "${CAP}s" \
      -p "${AGY_NOSHELL}${NL}${NL}${PROMPT}" >"$OUT" 2>"$LOG"
    cat "$LOG" >>"$attempts"
    grep -qiE "$AGY_MODEL_ERR" "$LOG" && continue
    echo "$m" >"${OUT%.md}.model"
    # Cache only a slug that produced a valid report.
    if [ "$(rc_validate_report "$OUT" "$LOG" | cut -d'|' -f1)" = "ok" ]; then
      mkdir -p "$(dirname "$AGY_MODEL_CACHE")" 2>/dev/null && printf '%s\n%s\n' "$m" "$all" >"$AGY_MODEL_CACHE"
    fi
    return 0
  done
  cat "$attempts" >"$LOG"
  return 1
}

# shellcheck source=../lib/seat.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/seat.sh"
seat_main "$@"
