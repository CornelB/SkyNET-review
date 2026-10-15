#!/usr/bin/env bash
# grok seat: grok CLI, read-only sandbox, effort xhigh. Contract: lib/seat.sh.
#
# PRE-FLIGHT (before the cap clock matters): a trivial no-op under
# `--sandbox read-only`. On a host where the sandbox cannot be built
# ("sandbox profile resolve failed ... podman.sock: Permission denied") grok
# exits in milliseconds and would otherwise sit as did-not-report.
# LINUX-ONLY recovery, no privileges (macOS Seatbelt and Windows build these
# profiles fine and are left untouched): grok's read-only profile
# kernel-denies the container runtime socket and refuses to start when its
# path cannot even be stat-ed (rootful podman leaves /run/podman 0700 root).
# The pre-flight then retries inside an unprivileged user namespace
# (`unshare -Urm`) with an empty tmpfs over that directory, and the seat
# launches through the same wrapper. The socket is hidden outright, stronger
# than the deny, never weaker; grok's own sandbox is still built inside, and
# no grok flag changes. The mask is named in the status line. Fails closed:
# if masking does not make the no-op pass, the seat is skipped.
#
# The launcher starts this seat's four lenses at once; the first one runs
# the pre-flight under a lock and the others reuse its result.
#
# `max` effort is rejected ("use one of: xhigh, high, medium, low") and the
# rejection exits 0 onto stdout; the launcher's validation screens for it.
set -u
SEAT=grok
GROK_PREFLIGHT_SECS=45
GROK_SANDBOX_ERR='sandbox profile resolve failed|could not enforce its deny list|bwrap'
GROK_MASK_DIRS=""

# Every grok invocation goes through here. With GROK_MASK_DIRS empty it is
# plain `grok`; otherwise an unprivileged user+mount namespace in which each
# listed directory is replaced by an empty tmpfs, then grok runs unchanged.
grok_exec() {
  if [ -z "$GROK_MASK_DIRS" ]; then grok "$@"; return; fi
  # shellcheck disable=SC2016 # $0 and $@ expand in the inner sh, not here.
  unshare -Urm --propagation unchanged sh -c '
    for d in $0; do mount -t tmpfs -o nosuid,nodev,noexec none "$d" || exit 97; done
    exec "$@"' "$GROK_MASK_DIRS" grok "$@"
}

# Sets GROK_MASK_DIRS; returns 0 when the seat may launch, else sets
# GATE_REASON. A cap hit is inconclusive and lets the real launch proceed.
grok_preflight() {
  pf_err="$OUTDIR/grok-preflight.log" pf_try="$OUTDIR/grok-preflight.try.$$"
  : >"$pf_err"; tries=0
  while :; do
    rc_run_capped "$GROK_PREFLIGHT_SECS" grok_exec --sandbox read-only -p "Reply with the single word OK." >/dev/null 2>"$pf_try"
    rc=$?
    cat "$pf_try" >>"$pf_err"
    [ "$rc" -eq 124 ] && { rm -f "$pf_try"; return 0; }
    if [ "$rc" -eq 0 ] && ! grep -qiE "$GROK_SANDBOX_ERR" "$pf_try" 2>/dev/null; then
      [ -n "$GROK_MASK_DIRS" ] && echo "== ok with $GROK_MASK_DIRS masked ==" >>"$pf_err"
      rm -f "$pf_try"; return 0
    fi
    bad=$(sed -nE 's/.*could not resolve [^ ]* deny path ([^ :]+):.*/\1/p' "$pf_try" | tail -n 1)
    if [ -n "$bad" ] && [ "$(uname -s)" = Linux ] && command -v unshare >/dev/null 2>&1 && [ "$tries" -lt 3 ]; then
      dir=$(dirname "$bad")
      case " $GROK_MASK_DIRS " in *" $dir "*) ;; *) GROK_MASK_DIRS="${GROK_MASK_DIRS:+$GROK_MASK_DIRS }$dir";; esac
      echo "== retrying with $dir masked by an empty tmpfs (unshare -Urm) ==" >>"$pf_err"
      tries=$((tries + 1))
      continue
    fi
    reason=$(grep -m1 -iE "$GROK_SANDBOX_ERR|error" "$pf_try" | head -c 200)
    rm -f "$pf_try"
    GATE_REASON="pre-flight failed (exit $rc): ${reason:-see grok-preflight.log}"
    return 1
  done
}

# One pre-flight per run directory: the first lens takes the lock and writes
# the result, the others wait for it.
grok_preflight_once() {
  result="$OUTDIR/grok-preflight.result"
  if mkdir "$OUTDIR/.grok-preflight.lock" 2>/dev/null; then
    if grok_preflight; then echo "ok|$GROK_MASK_DIRS" >"$result.tmp"
    else echo "fail|$GATE_REASON" >"$result.tmp"; fi
    mv "$result.tmp" "$result"
  fi
  i=0
  while [ ! -f "$result" ] && [ "$i" -lt $((GROK_PREFLIGHT_SECS * 4 + 10)) ]; do sleep 1; i=$((i + 1)); done
  [ -f "$result" ] || { GATE_REASON="pre-flight result never appeared"; return 1; }
  line=$(cat "$result")
  case "$line" in
    ok\|*) GROK_MASK_DIRS=${line#ok|}; return 0 ;;
    *) GATE_REASON=${line#fail|}; return 1 ;;
  esac
}

seat_gate() {
  command -v grok >/dev/null 2>&1 || { GATE_REASON="grok not on PATH"; return 1; }
  # Discovery (-c) has no run directory: the pre-flight belongs to a run.
  [ "$CHECK" -eq 1 ] && return 0
  grok_preflight_once
}

seat_describe() {
  echo "default model, xhigh, read-only sandbox${GROK_MASK_DIRS:+; masked $GROK_MASK_DIRS via unshare, see grok-preflight.log}"
}

seat_invoke() {
  grok_exec --sandbox read-only --effort xhigh -p "$PROMPT" >"$OUT" 2>"$LOG"
}

# shellcheck source=../lib/seat.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/seat.sh"
seat_main "$@"
