#!/usr/bin/env bash
# antigravity seat: agy CLI, --sandbox, no --mode, no shell. Contract:
# lib/seat.sh. No gemini-cli fallback.
#
# PERMISSIONS. Headless agy auto-denies any tool permission it cannot prompt
# for, and one denial ends the run. agy has three permission classes:
# command, read_file, write_file. This seat grants read_file ONLY, through a
# PINNED allow-list merged into ~/.gemini/antigravity-cli/settings.json:
#   - No `command` rule: agy matches a command rule against the FULL command
#     string, and an agentic reviewer emits a different line every time, so
#     no scoped shell rule can match. The only rule that would is
#     `command(*)`: blanket shell approval on an untrusted tree, which this
#     plugin refuses. So the seat gets no shell and is told so in its prompt.
#   - `write_file` is deliberately absent and must stay absent. With no shell
#     and no write permission, read-only is enforced by the CLI.
#   - No `--mode plan`: plan mode stops and waits for a Proceed click, so the
#     seat writes a plan file and never reviews.
#   - read_file(*) lets the seat read any file the user can, not only the
#     worktree: path-scoped rules cannot work because the worktree path is
#     per-run, and nothing from the invocation may influence what is written
#     to settings. It grants no writes and no shell.
# The merge is idempotent, keeps a backup, preserves every other key, and is
# named in the status line. `antigravity.sh setup` runs it by hand.
#
# MODEL. Highest-ranked slug from `agy models`, flash family first (newest
# version, high effort), pro only as the fallback floor. Effort is baked into
# the slug. Candidates are tried in order because a listed model can still be
# unavailable to the account; each such failure is immediate. The slug that
# last produced a valid report is cached in
# $XDG_CACHE_HOME/review-board/agy-model and tried first.
set -u
SEAT=antigravity

AGY_SETTINGS="$HOME/.gemini/antigravity-cli/settings.json"
AGY_ALLOWS='read_file(*)'
AGY_FALLBACK="gemini-3.7-flash-high gemini-3.1-pro-high"
AGY_MODEL_ERR='invalid model selection|not recognized as a known model|not supported in the selected location|required the "command" permission'
AGY_MODEL_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/review-board/agy-model"
AGY_NOSHELL="HARD CONSTRAINT: you have NO shell access. Every shell command is auto-denied and one attempt ends your run with no report. Read the diff file and every source file ONLY with your native file-reading tool, and ONLY by the absolute paths given in this prompt: a relative path does not resolve without a shell. If you cannot read a file, say so; reporting a value you did not read is a failed review."
NL='
'

agy_configured() { grep -q '"read_file(\*)"' "$AGY_SETTINGS" 2>/dev/null; }

# Merge the pinned allow-list, preserving every other key. Fixed content.
# JSON::PP is core perl (5.14+).
ensure_agy_config() {
  command -v perl >/dev/null 2>&1 || { echo "agy auto-config needs perl" >&2; return 1; }
  mkdir -p "$(dirname "$AGY_SETTINGS")" 2>/dev/null || return 1
  [ -f "$AGY_SETTINGS" ] && { cp "$AGY_SETTINGS" "$AGY_SETTINGS.bak" || return 1; }
  ALLOWS="$AGY_ALLOWS" SETTINGS="$AGY_SETTINGS" perl -MJSON::PP -e '
    my $f = $ENV{SETTINGS};
    my $data = {};
    if (-f $f) {
      local $/; open my $in, "<", $f or die "read $f: $!";
      my $txt = <$in>; $data = JSON::PP->new->decode($txt) if $txt =~ /\S/;
    }
    my %have = map { $_ => 1 } @{ $data->{permissions}{allow} // [] };
    my @add = grep { !$have{$_} } split " ", $ENV{ALLOWS};
    push @{ $data->{permissions}{allow} }, @add;
    open my $out, ">", $f or die "write $f: $!";
    print $out JSON::PP->new->pretty->canonical->encode($data);
    print @add ? "added: @add\n" : "already configured, nothing to do\n";
  '
}

# Ordered model candidates: flash before pro, newer first, higher effort first.
agy_candidates() {
  command -v perl >/dev/null 2>&1 || return 0
  agy models 2>/dev/null | perl -ne '
    BEGIN { @m = (); %rank = (high => 0, medium => 1, low => 2) }
    next unless /^(gemini-([0-9]+(?:\.[0-9]+)?)-(pro|flash)-(high|medium|low))\b/;
    my ($slug, $ver, $tier, $eff) = ($1, $2, $3, $4);
    my @p = split /\./, $ver;
    push @m, [ $tier eq "flash" ? 0 : 1, -($p[0] * 1000 + ($p[1] // 0)), $rank{$eff}, $slug ];
    END {
      @m = sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] || $a->[2] <=> $b->[2] } @m;
      print join(" ", map { $_->[3] } @m);
    }
  ' 2>/dev/null
}

if [ "${1:-}" = "setup" ]; then
  ensure_agy_config || { echo "antigravity.sh: setup failed; original (if any) kept at $AGY_SETTINGS.bak" >&2; exit 2; }
  echo "done: $AGY_SETTINGS"
  exit 0
fi

AGY_STATE=""

seat_gate() {
  command -v agy >/dev/null 2>&1 || { GATE_REASON="agy not on PATH"; return 1; }
  [ "$CHECK" -eq 1 ] && return 0
  if ! agy_configured; then
    # Four lenses start at once; one merges, the others wait for it.
    if mkdir "$OUTDIR/.agy-setup.lock" 2>/dev/null; then
      if ensure_agy_config >"$OUTDIR/agy-setup.log" 2>&1; then
        AGY_STATE="; auto-configured allow-list (agy-setup.log)"
      else
        GATE_REASON="allow-list auto-config failed (agy-setup.log)"; return 1
      fi
    else
      i=0; while ! agy_configured && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
      agy_configured || { GATE_REASON="allow-list auto-config did not complete"; return 1; }
    fi
  fi
  return 0
}

seat_describe() {
  used=$(cat "${OUT%.md}.model" 2>/dev/null)
  echo "${used:-best flash slug}, --sandbox, read_file only$AGY_STATE"
}

# Walk the candidates past model-selection errors. Each attempt overwrites the
# log so a rejected candidate's message cannot condemn a later good report;
# the whole trail is kept aside and restored only when every candidate fails.
seat_invoke() {
  attempts="${OUT%.md}.attempts.log"
  : >"$attempts"
  models=$(agy_candidates)
  [ -n "$models" ] || models=$AGY_FALLBACK
  cached=""; [ -f "$AGY_MODEL_CACHE" ] && cached=$(tr -cd 'a-zA-Z0-9.-' <"$AGY_MODEL_CACHE")
  if [ -n "$cached" ]; then
    rest=""; for m in $models; do [ "$m" = "$cached" ] || rest="$rest $m"; done
    models="$cached$rest"
  fi
  for m in $models; do
    echo "== agy model $m ==" >>"$attempts"
    agy --sandbox --model "$m" --print-timeout "${CAP}s" \
      -p "${AGY_NOSHELL}${NL}${NL}${PROMPT}" >"$OUT" 2>"$LOG"
    cat "$LOG" >>"$attempts"
    grep -qiE "$AGY_MODEL_ERR" "$LOG" && continue
    echo "$m" >"${OUT%.md}.model"
    # Cache only a slug that produced a valid report.
    if [ "$(rc_validate_report "$OUT" "$LOG" | cut -d'|' -f1)" = "ok" ]; then
      mkdir -p "$(dirname "$AGY_MODEL_CACHE")" 2>/dev/null && echo "$m" >"$AGY_MODEL_CACHE"
    fi
    return 0
  done
  cat "$attempts" >"$LOG"
  return 1
}

# shellcheck source=../lib/seat.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/seat.sh"
seat_main "$@"
