#!/usr/bin/env bash
# tribunal.sh — launcher for grumpy-review's external tribunal seats.
#
# WHY THIS SCRIPT EXISTS
#   Every reviewer-CLI flag lives HERE, version-controlled and reviewable:
#   - The harness allowlist needs ONE rule matching this script, not one
#     order-sensitive prefix rule per CLI flag combination.
#   - No agent composes reviewer flags inline, so neither drift nor a
#     prompt-injected diff can weaken an invocation.
#   - It contains NO approval bypasses (--dangerously-skip-permissions,
#     --yolo) and takes no passthrough flags, so none can be added at the
#     call site. agy headless tool permissions come from the operator's
#     ~/.gemini/antigravity-cli/settings.json allow-list, which this script
#     writes itself (see AGY_ALLOWS); a seat denied there ends up
#     "did-not-report" — by design.
#
# USAGE
#   tribunal.sh -w <worktree> -p <prompt-file> -o <outdir> [-t seconds] [seat ...]
#     seats: codex gemini claude grok   (default: all; the gemini seat prefers
#            agy — auto-configured — and falls back to the deprecated
#            gemini-cli when agy is not installed)
#     -t    wall-clock cap for all seats, default 600
#
# PRE-FLIGHT (runs BEFORE the -t clock starts; a failed seat costs seconds,
# not the whole budget, and is reported `skipped|<reason>` right away):
#   grok:   a trivial `grok --sandbox read-only -p` no-op. On a host where the
#           sandbox cannot be built ("sandbox profile resolve failed … podman
#           .sock: Permission denied", bwrap plan) grok exits in milliseconds
#           and would otherwise sit as did-not-report for the full -t.
#           LINUX-ONLY recovery, no privileges (macOS Seatbelt and Windows
#           build these profiles fine and are left untouched): grok's read-only/strict profiles
#           kernel-deny the container runtime socket and refuse to start when
#           its path cannot even be stat-ed (rootful podman leaves /run/podman
#           0700 root). The pre-flight then retries inside an unprivileged user
#           namespace (`unshare -Urm`) with an empty tmpfs over that directory,
#           and the seat launches through the same wrapper. The socket is
#           hidden outright — stronger than the deny, never weaker — grok's
#           own sandbox is still built inside, and no grok flag changes. The
#           mask is named in the status line. Fails closed: if masking does
#           not make the no-op pass, the seat is skipped.
#   agy:    the model slug that last produced a report is cached in
#           $XDG_CACHE_HOME/grumpy-review/agy-model (default ~/.cache/…) and
#           tried FIRST, so the walk past listed-but-unavailable pro models
#           (minutes per run) happens once per machine, not once per review.
#
#   tribunal.sh setup-agy
#     Manual form of the agy auto-configuration (normally not needed): merges
#     the PINNED read-only allow-list (read_file only — no shell) into
#     ~/.gemini/antigravity-cli/settings.json. The launcher runs the same
#     merge automatically before the first agy launch on an unconfigured
#     machine — idempotent, fixed content, backup kept, reported in output.
#     Zero user setup by design.
#
# SKILL ACTIVATION
#   Every seat is expected to have the grumpy-review skill installed on its
#   side. The launcher prepends the per-CLI activation token to the prompt:
#   codex expands `$grumpy-review`, agy/gemini expand `/grumpy-review`.
#   The prompt file itself must stay self-contained (persona + contract) so
#   a seat without the skill still reviews — activation is additive.
#
# MODEL SELECTION
#   agy:    --sandbox, NO --mode (plan mode waits for a Proceed click and never
#           reviews), no shell permission at all; highest-ranked slug from
#           `agy models`, FLASH family first (newest version, high effort),
#           pro only as the fallback floor. Effort is BAKED INTO THE SLUG —
#           `--effort` is rejected outright for pro models, and bare aliases
#           ("pro") are not recognized. Candidates are tried in order because
#           a listed model can still be unavailable to the account ("not
#           supported in the selected location"). Flash leads because pro has
#           been unavailable to the account and shells out (and dies) on the
#           no-shell prompt flash obeys — each pro attempt cost minutes.
#   gemini: --model pro            (fallback only; no --effort on gemini-cli)
#   codex:  highest-priority listed model, preferring gpt-*sol slugs, read
#           from `codex debug models` (jq-free perl scan); effort xhigh via
#           -c model_reasoning_effort. Discovery failure => codex's default
#           model — a weaker seat beats a dead one.
#   claude: --permission-mode plan --model fable --effort xhigh
#           (plan = read-only auto-approval, matching the other seats)
#   grok:   --sandbox read-only --effort xhigh, CLI-default model.
#           xhigh is the ceiling: `max` is rejected ("use one of: xhigh, high,
#           medium, low") and the rejection exits 0 onto stdout, so validate()
#           screens for it rather than trusting the exit code.
#
# OUTPUT
#   <outdir>/codex.md, <outdir>/gemini.md   reviewer reports
#   <outdir>/codex.log, <outdir>/gemini.log stderr / session noise
#   stdout, one line per seat:   <seat>|<status>|<detail>
#     status: ok | skipped | did-not-report
#   Exit 0 unless the invocation itself is unusable — a failed seat is a
#   reported status, not a script failure.
#
# Portable: Linux, macOS (bash 3.2 — no associative arrays), Windows Git
# Bash (no GNU timeout — watchdog loop instead).

set -u

die() { echo "tribunal.sh: $*" >&2; exit 2; }

AGY_SETTINGS="$HOME/.gemini/antigravity-cli/settings.json"
# agy has exactly three permission classes: command, read_file, write_file.
# The list below grants read_file ONLY — no `command` rule at all, so every
# shell-out is auto-denied. That is deliberate and hard-won:
#   - agy's `command(...)` rules match the FULL command string, not the program
#     name. `command(cat)`, `command(cat *)`, even the exact string a previous
#     run emitted — none of them match the next invocation, because an agentic
#     reviewer composes a different line every time (observed: `Test-Path "…"`,
#     then `Get-ChildItem -Path . -Filter … -Recurse`, then `if (Test-Path …)`).
#     A scoped shell allow-list is therefore unachievable, and the only rule
#     that would work is `command(*)` — blanket shell approval on an untrusted
#     tree, i.e. exactly the bypass this script refuses to contain.
#   - So the seat gets NO shell and is told so in its prompt (AGY_NOSHELL): it
#     reads the diff and the tree through its native file tool, which needs
#     `read_file(*)`. Path-scoped read rules cannot work here — the worktree
#     path is per-run, and pinning a dynamic value would break the guarantee
#     that nothing from the invocation influences what is written to settings.
#   - `write_file`: DELIBERATELY ABSENT, and must stay absent. With no shell and
#     no write permission, "read-only reviewer" is enforced by the CLI rather
#     than promised by a flag — which matters now that `--mode plan` is gone
#     (plan mode does not auto-approve read-only tools: it stops and waits for a
#     Proceed click, so the seat emitted a plan file and never reviewed).
# Scope honestly stated: read_file(*) lets the seat read any file the user can,
# not just the worktree. That is the standing tradeoff for a cloud reviewer; it
# grants no writes and no shell whatsoever.
AGY_ALLOWS='read_file(*)'

# agy needs its headless allow-list — otherwise its native file reads auto-deny
# and the seat dies on the first file it opens. Crude but sufficient probe.
agy_configured() { grep -q '"read_file(\*)"' "$AGY_SETTINGS" 2>/dev/null; }

# Merge the PINNED read-only allow-list into agy's settings, preserving every
# other key. Fixed content — nothing from the invocation or the reviewed tree
# can influence what is written. JSON::PP is core perl (5.14+). Returns
# non-zero on failure (no perl, unwritable HOME, malformed settings).
ensure_agy_config() {
  command -v perl >/dev/null 2>&1 || { echo "tribunal.sh: agy auto-config needs perl" >&2; return 1; }
  mkdir -p "$(dirname "$AGY_SETTINGS")" 2>/dev/null || return 1
  BACKUP_MSG="(new file)"
  [ -f "$AGY_SETTINGS" ] && { cp "$AGY_SETTINGS" "$AGY_SETTINGS.bak" || return 1; BACKUP_MSG="(backup: $AGY_SETTINGS.bak)"; }
  # AGY_ALLOWS is space-separated, so a rule needing a literal space writes `~`
  # instead and perl restores it (never `_` — rule names contain underscores).
  ALLOWS="$AGY_ALLOWS" SETTINGS="$AGY_SETTINGS" perl -MJSON::PP -e '
    my $f = $ENV{SETTINGS};
    my $data = {};
    if (-f $f) {
      local $/; open my $in, "<", $f or die "read $f: $!";
      my $txt = <$in>; $data = JSON::PP->new->decode($txt) if $txt =~ /\S/;
    }
    my %have = map { $_ => 1 } @{ $data->{permissions}{allow} // [] };
    my @add = grep { !$have{$_} } map { s/~/ /gr } split " ", $ENV{ALLOWS};
    push @{ $data->{permissions}{allow} }, @add;
    open my $out, ">", $f or die "write $f: $!";
    print $out JSON::PP->new->pretty->canonical->encode($data);
    print @add ? "added: @add\n" : "already configured — nothing to do\n";
    print "allow-list now: @{ $data->{permissions}{allow} }\n";
  '
}

# Manual form; the launcher normally auto-configures before the first agy run.
if [ "${1:-}" = "setup-agy" ]; then
  ensure_agy_config || die "setup-agy failed; original (if any) preserved at $AGY_SETTINGS.bak"
  echo "done: $AGY_SETTINGS $BACKUP_MSG"
  exit 0
fi

WORKTREE="" PROMPT_FILE="" OUTDIR="" TIMEOUT=600
while getopts "w:p:o:t:h" opt; do
  case "$opt" in
    w) WORKTREE=$OPTARG ;;
    p) PROMPT_FILE=$OPTARG ;;
    o) OUTDIR=$OPTARG ;;
    t) TIMEOUT=$OPTARG ;;
    h) sed -n '2,80p' "$0"; exit 0 ;;
    *) die "unknown flag — run with -h" ;;
  esac
done
shift $((OPTIND - 1))
SEATS=${*:-codex gemini claude grok}

[ -n "$WORKTREE" ] && [ -n "$PROMPT_FILE" ] && [ -n "$OUTDIR" ] || die "need -w <worktree> -p <prompt-file> -o <outdir>"
[ -d "$WORKTREE" ] || die "worktree is not a directory: $WORKTREE"
[ -f "$PROMPT_FILE" ] || die "prompt file not found: $PROMPT_FILE"
case "$TIMEOUT" in *[!0-9]*|"") die "-t takes seconds (integer)";; esac
mkdir -p "$OUTDIR" || die "cannot create outdir: $OUTDIR"
# Absolute-ize both paths NOW: every seat runs `cd "$WORKTREE"` first, and a
# relative -o would then resolve its report redirections inside the reviewed
# tree — polluting it, or failing outright.
OUTDIR=$(cd "$OUTDIR" && pwd) || die "cannot resolve outdir: $OUTDIR"
WORKTREE=$(cd "$WORKTREE" && pwd) || die "cannot resolve worktree: $WORKTREE"
PROMPT=$(cat "$PROMPT_FILE") || die "cannot read prompt file"
[ -n "$PROMPT" ] || die "prompt file is empty"

# Per-CLI skill activation (see header): codex uses $name, agy/gemini /name.
SKILL_NAME="grumpy-review"
NL='
'
PROMPT_CODEX="\$${SKILL_NAME}${NL}${NL}${PROMPT}"
PROMPT_SLASH="/${SKILL_NAME}${NL}${NL}${PROMPT}"
# agy runs with zero shell permission (see AGY_ALLOWS): a single shell attempt is
# auto-denied and ends the run with no report, so the constraint is stated up
# front rather than discovered. Additive, like the skill token — the prompt file
# itself stays CLI-agnostic.
AGY_NOSHELL="HARD CONSTRAINT — you have NO shell access. Every shell command is auto-denied and one attempt ends your run with no report. Read the diff file and every source file ONLY with your native file-reading tool, and ONLY by the absolute paths given in this prompt: a relative path does not resolve without a shell. If you cannot read a file, say so — reporting a value you did not read is a failed review."
PROMPT_AGY="/${SKILL_NAME}${NL}${NL}${AGY_NOSHELL}${NL}${NL}${PROMPT}"

# Model selection (see header).
AGY_FALLBACK="gemini-3.7-flash-high gemini-3.1-pro-high"   # used only if discovery fails
# Conditions that make the NEXT candidate worth trying. Model-selection errors
# are obvious. The permission denial is not, and is the expensive lesson: the
# AGY_NOSHELL instruction is a prompt, not a constraint, and compliance is
# model-dependent — pro has been observed shelling out (and dying) on a prompt
# flash obeys. Without this, one non-compliant top-ranked model kills the seat
# outright instead of falling through to one that reviews fine.
AGY_MODEL_ERR='invalid model selection|not recognized as a known model|not supported in the selected location|required the "command" permission'
GEMINI_MODEL="pro"                       # fallback seat; no --effort on gemini-cli
CODEX_EFFORT='model_reasoning_effort="xhigh"'
CLAUDE_MODEL="fable" CLAUDE_EFFORT="xhigh"
GROK_EFFORT="xhigh"                      # CLI-default model; `max` is rejected
AGY_MODEL_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/grumpy-review/agy-model"
GROK_PREFLIGHT_SECS=45                    # cap for the no-op; a working seat answers in seconds
GROK_SANDBOX_ERR='sandbox profile resolve failed|could not enforce its deny list|bwrap'
GROK_MASK_DIRS="" GROK_PF_REASON=""       # set by grok_preflight

# Run "$@" with a wall-clock cap (portable: no GNU timeout). Exit 124 on cap.
run_capped() { # $1=seconds, rest=command
  secs=$1; shift
  "$@" & cpid=$!
  ( i=0; while [ "$i" -lt "$secs" ]; do sleep 1; kill -0 "$cpid" 2>/dev/null || exit 0; i=$((i + 1)); done
    kill "$cpid" 2>/dev/null ) & wpid=$!
  wait "$cpid" 2>/dev/null; rc=$?
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  if kill -0 "$cpid" 2>/dev/null || [ "$rc" -eq 143 ]; then return 124; fi
  return "$rc"
}

# Every grok invocation goes through here. With GROK_MASK_DIRS empty it is
# plain `grok`; otherwise an unprivileged user+mount namespace in which each
# listed directory is replaced by an empty tmpfs (private to that namespace),
# then grok runs unchanged. No fork: unshare execs sh, sh execs grok, so the
# watchdog's kill reaches grok itself.
grok_exec() {
  if [ -z "$GROK_MASK_DIRS" ]; then grok "$@"; return; fi
  unshare -Urm --propagation unchanged sh -c '
    for d in $0; do mount -t tmpfs -o nosuid,nodev,noexec none "$d" || exit 97; done
    exec "$@"' "$GROK_MASK_DIRS" grok "$@"
}

# grok pre-flight: a no-op prompt proves the sandbox can be constructed on this
# host. Deterministic failure => skipped now, instead of did-not-report after
# the full -t. A cap hit is inconclusive and lets the real launch proceed.
# When the failure is an unresolvable deny path (see header), up to three
# directories are masked via grok_exec and the no-op is retried.
grok_preflight() { # returns 0 when the seat may launch; failure reason in $GROK_PF_REASON.
  # Runs in the parent shell (not $(...)) so GROK_MASK_DIRS reaches the launch.
  pf_err="$OUTDIR/grok-preflight.log" pf_try="$OUTDIR/grok-preflight.try"
  : >"$pf_err"; tries=0
  while :; do
    # Each attempt's stderr is judged on its own; the log keeps the whole trail.
    run_capped "$GROK_PREFLIGHT_SECS" grok_exec --sandbox read-only -p "Reply with the single word OK." >/dev/null 2>"$pf_try"
    rc=$?
    cat "$pf_try" >>"$pf_err"
    [ "$rc" -eq 124 ] && { rm -f "$pf_try"; return 0; }
    if [ "$rc" -eq 0 ] && ! grep -qiE "$GROK_SANDBOX_ERR" "$pf_try" 2>/dev/null; then
      [ -n "$GROK_MASK_DIRS" ] && echo "== ok with $GROK_MASK_DIRS masked ==" >>"$pf_err"
      rm -f "$pf_try"; return 0
    fi
    bad=$(sed -nE 's/.*could not resolve [^ ]* deny path ([^ :]+):.*/\1/p' "$pf_try" | tail -n 1)
    # Linux only: the mask is a user+mount namespace, which macOS (Seatbelt)
    # and Windows do not have — and do not need; their built-in profiles work.
    if [ -n "$bad" ] && [ "$(uname -s)" = Linux ] && command -v unshare >/dev/null 2>&1 && [ "$tries" -lt 3 ]; then
      dir=$(dirname "$bad")
      case " $GROK_MASK_DIRS " in *" $dir "*) ;; *) GROK_MASK_DIRS="${GROK_MASK_DIRS:+$GROK_MASK_DIRS }$dir";; esac
      echo "== retrying with $dir masked by an empty tmpfs (unshare -Urm) ==" >>"$pf_err"
      tries=$((tries + 1))
      continue
    fi
    reason=$(grep -m1 -iE "$GROK_SANDBOX_ERR|error" "$pf_try" | head -c 200)
    rm -f "$pf_try"
    GROK_PF_REASON="pre-flight failed (exit $rc): ${reason:-see grok-preflight.log}"
    return 1
  done
}

# Highest-priority listed codex model, gpt-*sol slugs first. Empty on any
# failure (no perl, auth error, format drift) => run codex on its default.
codex_best_model() {
  command -v perl >/dev/null 2>&1 || return 0
  codex debug models 2>/dev/null | perl -0777 -ne '
    my @m;
    for my $c (split /(?=\{"slug":")/, $_) {
      next unless $c =~ /^\{"slug":"([^"]+)"/; my $s = $1;
      next unless $c =~ /"visibility":"list"/;
      my $p = $c =~ /"priority":(\d+)/ ? $1 : 9999;
      push @m, [($s =~ /^gpt-.*sol/ ? 0 : 1), $p, $s];
    }
    @m = sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @m;
    print $m[0][2] if @m;
  ' 2>/dev/null
}

# Ordered agy model candidates: flash before pro, newer version first, higher
# baked-in effort first. Empty on any failure => AGY_FALLBACK.
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

# Run the agy seat, walking the candidate list past model-selection errors
# (unrecognized slug, or listed-but-unavailable-to-this-account). Each such
# failure is immediate and costs no model call. Records the model that stuck
# in agy-model.txt — a backgrounded subshell cannot set a parent variable.
# Each attempt's stderr must stay ISOLATED: a rejected candidate's message
# accumulated into gemini.log would (a) re-match on the next iteration and
# (b) make validate() condemn a report a later candidate produced fine. So
# the loop overwrites the log per attempt and keeps the trail aside, pasting
# it back only when every candidate was rejected.
agy_run() { # $1=outfile $2=logfile ; runs in the background subshell
  attempts="$OUTDIR/agy-attempts.log"
  : >"$attempts"
  # Discovery lives HERE, not in the parent: it is a network call, and the
  # watchdog does not exist yet while the seat loop runs — a stalled
  # `agy models` in the parent would hold back every later seat and the
  # timeout itself.
  models=$(agy_candidates)
  [ -n "$models" ] || models=$AGY_FALLBACK
  # The slug that last produced a report on this machine goes first; the
  # discovered list follows (minus that slug) so a revoked cache still walks.
  cached=""; [ -f "$AGY_MODEL_CACHE" ] && cached=$(tr -cd 'a-zA-Z0-9.-' <"$AGY_MODEL_CACHE")
  if [ -n "$cached" ]; then
    rest=""; for m in $models; do [ "$m" = "$cached" ] || rest="$rest $m"; done
    models="$cached$rest"
    echo "== cached model first: $cached ($AGY_MODEL_CACHE) ==" >>"$attempts"
  fi
  for m in $models; do
    echo "== agy model $m ==" >>"$attempts"
    agy --sandbox --model "$m" \
      --print-timeout "${TIMEOUT}s" -p "$PROMPT_AGY" >"$1" 2>"$2"
    cat "$2" >>"$attempts"
    grep -qiE "$AGY_MODEL_ERR" "$2" && continue
    echo "$m" >"$OUTDIR/agy-model.txt"
    # Cache only a slug that produced a VALID report: a run killed by a
    # permission denial or an empty answer must not become the default.
    if [ "$(validate "$1" "$2" | cut -d'|' -f1)" = "ok" ]; then
      mkdir -p "$(dirname "$AGY_MODEL_CACHE")" 2>/dev/null && echo "$m" >"$AGY_MODEL_CACHE"
    fi
    return 0
  done
  cat "$attempts" >"$2"
  return 1
}

# Validation — exit codes lie (a rejected flag can still exit 0, and can land
# on stdout, i.e. in the report file). Checks: a headless permission denial; a
# rejected invocation (usage dump, unknown flag/effort, unusable model) in the
# opening lines of EITHER stream; empty output. Caught => did-not-report.
validate() { # $1=outfile $2=logfile ; echoes "status|detail"
  out=$1 log=$2
  head3=$( { head -n 3 "$out"; head -n 3 "$log"; } 2>/dev/null )
  if grep -qiE 'auto-denied|permission request (was )?denied|no output produced' "$out" "$log" 2>/dev/null; then
    echo "did-not-report|tool permission denial (see $(basename "$log")) — do NOT widen the allow-list to fix it; read SKILL.md first"
  elif printf '%s\n' "$head3" | grep -qiE 'usage( of|:)|unknown (flag|option|effort level)|unrecognized (option|argument)|invalid model selection|not supported in the selected location'; then
    echo "did-not-report|CLI rejected the invocation (flags/model) — see $(basename "$log")"
  elif grep -qiE 'usage limit|quota exceeded|out of (credits|quota)|not authenticated|invalid api key' "$log" 2>/dev/null; then
    # Scanned in the LOG ONLY: a security review legitimately discusses rate
    # limits and credentials, and must not be thrown away for saying so.
    echo "did-not-report|quota or auth limit — no retry will help until it resets (see $(basename "$log"))"
  elif [ ! -s "$out" ]; then
    echo "did-not-report|empty output (see $(basename "$log"))"
  elif ! awk 'NF{print; exit}' "$out" | tr -d '*#`>_' | grep -qiE '^[[:space:]]*(verdict[[:space:]]*:?[[:space:]]*)?(pass|fail)'; then
    # Output contract: line 1 is the verdict. Anything else (a banner, an
    # error, a plan file, a chatty preamble) is not a report.
    echo "did-not-report|no verdict on line 1 (see $(basename "$out"))"
  else
    echo "ok|$out"
  fi
}

# Per-seat state (bash-3.2-safe scalars, no associative arrays).
PID_CODEX="" PID_GEMINI="" PID_CLAUDE="" PID_GROK=""
DETAIL_CODEX="" DETAIL_GEMINI="" DETAIL_CLAUDE="" DETAIL_GROK=""   # set => seat resolved before validation
GEMINI_BIN="" CODEX_NOTE="" CLAUDE_NOTE="" GROK_NOTE=""

for seat in $SEATS; do
  case "$seat" in
    codex)
      if command -v codex >/dev/null 2>&1; then
        CODEX_MODEL=$(codex_best_model)
        ( codex exec -C "$WORKTREE" --sandbox read-only \
            ${CODEX_MODEL:+-m "$CODEX_MODEL"} -c "$CODEX_EFFORT" \
            -o "$OUTDIR/codex.md" "$PROMPT_CODEX" \
            >"$OUTDIR/codex.log" 2>&1 ) &
        PID_CODEX=$!
        CODEX_NOTE="(${CODEX_MODEL:-default model}, xhigh)"
      else
        DETAIL_CODEX="skipped|codex CLI not installed"
      fi
      ;;
    gemini)
      # The gemini seat is agy — gemini-cli is deprecated and not supported.
      # No --disable-slash-commands: /grumpy-review expansion is the point.
      if command -v agy >/dev/null 2>&1; then
        AGY_STATE=""
        if ! agy_configured; then
          # Zero-friction install: write the pinned allow-list now, before
          # the first launch. Logged, backed up, surfaced in the status line.
          if ensure_agy_config >"$OUTDIR/agy-setup.log" 2>&1; then
            AGY_STATE="; auto-configured allow-list ($OUTDIR/agy-setup.log)"
          else
            AGY_STATE="; auto-config FAILED (see agy-setup.log)"
          fi
        fi
        : >"$OUTDIR/gemini.log"
        rm -f "$OUTDIR/agy-model.txt"
        ( cd "$WORKTREE" && agy_run "$OUTDIR/gemini.md" "$OUTDIR/gemini.log" ) &
        PID_GEMINI=$!
        GEMINI_BIN="agy$AGY_STATE"
      elif command -v gemini >/dev/null 2>&1; then
        # Fallback when agy is absent (gemini-cli is deprecated, kept for
        # coverage): --approval-mode plan = read-only auto-approval, the only
        # mode that works headless ("default" prompts; -p cannot answer).
        ( cd "$WORKTREE" && gemini --approval-mode plan \
            --model "$GEMINI_MODEL" -p "$PROMPT_SLASH" \
            >"$OUTDIR/gemini.md" 2>"$OUTDIR/gemini.log" ) &
        PID_GEMINI=$!
        GEMINI_BIN="gemini-cli, $GEMINI_MODEL"
      else
        DETAIL_GEMINI="skipped|neither agy nor gemini CLI installed"
      fi
      ;;
    claude)
      if ! command -v claude >/dev/null 2>&1; then
        DETAIL_CLAUDE="skipped|claude CLI not installed"
      elif ! claude auth status >/dev/null 2>&1; then
        # Unauthenticated -p runs can exit 0 with a non-report on stdout.
        DETAIL_CLAUDE="skipped|claude not authenticated (run: claude auth login)"
      else
        # plan = read-only auto-approval, same posture as the other seats.
        ( cd "$WORKTREE" && claude --permission-mode plan \
            --model "$CLAUDE_MODEL" --effort "$CLAUDE_EFFORT" \
            -p "$PROMPT_SLASH" \
            >"$OUTDIR/claude.md" 2>"$OUTDIR/claude.log" ) &
        PID_CLAUDE=$!
        CLAUDE_NOTE="($CLAUDE_MODEL, $CLAUDE_EFFORT)"
      fi
      ;;
    grok)
      if ! command -v grok >/dev/null 2>&1; then
        DETAIL_GROK="skipped|grok CLI not installed"
      elif ! grok_preflight; then
        DETAIL_GROK="skipped|$GROK_PF_REASON"
      else
        ( cd "$WORKTREE" && grok_exec --sandbox read-only \
            --effort "$GROK_EFFORT" -p "$PROMPT_SLASH" \
            >"$OUTDIR/grok.md" 2>"$OUTDIR/grok.log" ) &
        PID_GROK=$!
        GROK_NOTE="(default model, $GROK_EFFORT${GROK_MASK_DIRS:+; masked $GROK_MASK_DIRS via unshare, see grok-preflight.log})"
      fi
      ;;
    *)
      echo "$seat|skipped|unknown seat (valid: codex gemini claude grok)"
      ;;
  esac
done

# Kill a still-running seat and report how far it got. A timeout discards the
# whole run (reports are written at the end), so the byte counts exist to tell
# the caller whether a retry is worth the wall clock. They are ONE-WAY evidence:
# nonzero proves the seat was working and simply needs a bigger -t; zero proves
# nothing, because codex and grok stream as they go while claude and agy buffer
# everything until they finish. Hence the asymmetric hint below — do not
# "improve" it into reading 0B as a dead seat.
bytes() { b=$( { wc -c <"$1"; } 2>/dev/null | tr -cd '0-9'); echo "${b:-0}"; }
reap() { # $1=pid $2=outfile $3=logfile ; echoes a detail line, or fails if not running
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null || return 1
  kill "$1" 2>/dev/null
  ob=$(bytes "$2"); lb=$(bytes "$3")
  if [ "$ob" -gt 0 ] || [ "$lb" -gt 0 ]; then
    hint="was producing output — retry only with a larger -t"
  else
    hint="no bytes yet; inconclusive for buffering seats (claude, agy) — check the log"
  fi
  echo "did-not-report|timeout after ${TIMEOUT}s (report ${ob}B, log ${lb}B — $hint)"
}

# Watchdog — portable timeout (GNU timeout is absent on Git Bash / macOS).
deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  running=0
  for pid in $PID_CODEX $PID_GEMINI $PID_CLAUDE $PID_GROK; do
    kill -0 "$pid" 2>/dev/null && running=1
  done
  [ "$running" -eq 0 ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    D=$(reap "$PID_CODEX"  "$OUTDIR/codex.md"  "$OUTDIR/codex.log")  && DETAIL_CODEX=$D
    D=$(reap "$PID_GEMINI" "$OUTDIR/gemini.md" "$OUTDIR/gemini.log") && DETAIL_GEMINI=$D
    D=$(reap "$PID_CLAUDE" "$OUTDIR/claude.md" "$OUTDIR/claude.log") && DETAIL_CLAUDE=$D
    D=$(reap "$PID_GROK"   "$OUTDIR/grok.md"   "$OUTDIR/grok.log")   && DETAIL_GROK=$D
    break
  fi
  sleep 5
done
wait 2>/dev/null

for seat in $SEATS; do
  case "$seat" in
    codex)
      [ -z "$DETAIL_CODEX" ] && DETAIL_CODEX=$(validate "$OUTDIR/codex.md" "$OUTDIR/codex.log")
      [ -n "$CODEX_NOTE" ] && DETAIL_CODEX="$DETAIL_CODEX $CODEX_NOTE"
      echo "codex|$DETAIL_CODEX"
      ;;
    gemini)
      [ -z "$DETAIL_GEMINI" ] && DETAIL_GEMINI=$(validate "$OUTDIR/gemini.md" "$OUTDIR/gemini.log")
      if [ -n "$GEMINI_BIN" ]; then
        AGY_USED=$(cat "$OUTDIR/agy-model.txt" 2>/dev/null)
        DETAIL_GEMINI="$DETAIL_GEMINI (via $GEMINI_BIN${AGY_USED:+, $AGY_USED})"
      fi
      echo "gemini|$DETAIL_GEMINI"
      ;;
    claude)
      [ -z "$DETAIL_CLAUDE" ] && DETAIL_CLAUDE=$(validate "$OUTDIR/claude.md" "$OUTDIR/claude.log")
      [ -n "$CLAUDE_NOTE" ] && DETAIL_CLAUDE="$DETAIL_CLAUDE $CLAUDE_NOTE"
      echo "claude|$DETAIL_CLAUDE"
      ;;
    grok)
      [ -z "$DETAIL_GROK" ] && DETAIL_GROK=$(validate "$OUTDIR/grok.md" "$OUTDIR/grok.log")
      [ -n "$GROK_NOTE" ] && DETAIL_GROK="$DETAIL_GROK $GROK_NOTE"
      echo "grok|$DETAIL_GROK"
      ;;
  esac
done

exit 0
