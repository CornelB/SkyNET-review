#!/usr/bin/env bash
# pr-worktree.sh — materialize and tear down the exact tree a review-board
# run reviews. One script, two subcommands, so the harness allowlist needs
# ONE rule (`Bash(bash */review-board/scripts/pr-worktree.sh *)`) instead of
# approving `cd && git fetch && git worktree add && mkdir && gh pr diff > …`
# compound chains segment by segment on every round.
#
# USAGE
#   pr-worktree.sh [-C <repo>] prepare <N|PR-URL>
#     1. gh pr view            → title, body, baseRefName, headRefOid, url
#     2. wrong-repo guard      → the PR's owner/repo must match `git remote
#                                get-url origin` (a URL for another repo would
#                                fetch a DIFFERENT, real PR with the same N)
#     3. git worktree prune
#     4. git fetch origin pull/<N>/head          (FETCH_HEAD only, no refspec)
#     5. git worktree add --detach <tmp>/grumpy-pr-<N>-<oid7> <HEAD_OID>
#        — pinned to the OID, never FETCH_HEAD; reused if an identical
#        leftover is already registered at that OID
#     6. assert `git -C <worktree> rev-parse HEAD` == HEAD_OID
#     7. git fetch origin <base>; merge-base origin/<base> <HEAD_OID>
#     8. gh pr diff <N> → <outdir>/diff.patch; on failure falls back to
#        `git diff -M <merge-base>..HEAD` and says so (diff_source)
#     Prints ONE JSON line on stdout:
#       {"pr","url","title","worktree","outdir","head_oid","base",
#        "merge_base","diff_lines","diff_source","claims"}
#     `claims` is <outdir>/pr-body.md (title + body, the claims source).
#     Everything else goes to stderr. Exit 1 on any failure, nothing left
#     half-made that `cleanup` cannot sweep.
#
#   pr-worktree.sh [-C <repo>] cleanup <N>
#     `git worktree remove` (plain; `--force` only if the plain remove fails,
#     and that is reported), `git worktree prune`, sweep every registered or
#     stray `grumpy-pr-<N>-*` directory under the temp root, delete the
#     outdir(s). Idempotent — safe to run after a crashed round.
#
#   <tmp> is $CLAUDE_SCRATCHPAD, else $TMPDIR, else /tmp.
#   <outdir> is <tmp>/grumpy-pr-<N>-<oid7>.out
#
# SAFETY PROPERTIES (match SKILL.md "Hard constraints")
#   - Never creates, checks out, renames or deletes a branch or ref. The only
#     fetch forms are `git fetch origin pull/<N>/head` and
#     `git fetch origin <base>` — no destination refspec, ever.
#   - Writes only under <tmp>; never inside the repository.
#   - Takes no passthrough flags; nothing from the PR body reaches a command.
#
# Portable: Linux, macOS (bash 3.2), Git Bash. Needs git, gh; jq optional.

set -u

die() { echo "pr-worktree.sh: $*" >&2; exit 1; }
say() { echo "pr-worktree.sh: $*" >&2; }

REPO=""
while getopts "C:h" opt; do
  case "$opt" in
    C) REPO=$OPTARG ;;
    h) sed -n '2,45p' "$0"; exit 0 ;;
    *) die "unknown flag — run with -h" ;;
  esac
done
shift $((OPTIND - 1))
CMD=${1:-}; ARG=${2:-}
[ -n "$CMD" ] && [ -n "$ARG" ] || die "usage: pr-worktree.sh [-C <repo>] prepare <N|url> | cleanup <N>"

command -v git >/dev/null 2>&1 || die "git not installed"
if [ -n "$REPO" ]; then
  REPO=$(cd "$REPO" 2>/dev/null && pwd) || die "repo dir not found: $REPO"
else
  REPO=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository (use -C <repo>)"
fi
git() { command git -C "$REPO" "$@"; }

TMPROOT=${CLAUDE_SCRATCHPAD:-${TMPDIR:-/tmp}}
TMPROOT=${TMPROOT%/}
[ -d "$TMPROOT" ] || die "temp root does not exist: $TMPROOT"
case "$TMPROOT" in "$REPO"|"$REPO"/*) die "temp root is inside the repository: $TMPROOT";; esac

# PR number from "N", "#N", "PR-N", or a GitHub PR URL.
pr_number() {
  case "$1" in
    *://*) printf '%s\n' "$1" | sed -nE 's#^.*/pull/([0-9]+)([/?#].*)?$#\1#p' ;;
    *)     printf '%s\n' "$1" | sed -nE 's|^(PR-)?#?([0-9]+)$|\2|p' ;;
  esac
}
# owner/repo from a GitHub URL (https or ssh), lower-cased, .git stripped.
owner_repo() {
  printf '%s\n' "$1" | sed -nE 's#^(https?://[^/]+/|git@[^:]+:|ssh://git@[^/]+/)([^/]+/[^/]+).*$#\2#p' \
    | sed -E 's/\.git$//' | tr 'A-Z' 'a-z'
}
json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN{ORS=""} NR>1{print "\\n"} {print}'; }

N=$(pr_number "$ARG")
case "$N" in ''|*[!0-9]*) die "cannot parse a PR number from: $ARG";; esac

# ---------------------------------------------------------------- cleanup ---
if [ "$CMD" = "cleanup" ]; then
  removed=0 forced=0 stray=0
  # Registered worktrees named for this PR, wherever they live.
  for wt in $(git worktree list --porcelain | sed -nE 's#^worktree (.*/grumpy-pr-'"$N"'-[0-9a-f]+)$#\1#p'); do
    if git worktree remove "$wt" 2>/dev/null; then
      removed=$((removed + 1))
    elif git worktree remove --force "$wt"; then
      say "plain remove failed for $wt (modified or untracked files in a review worktree — a reviewer wrote into it); removed with --force"
      forced=$((forced + 1))
    else
      die "cannot remove worktree $wt"
    fi
  done
  git worktree prune
  # Strays: directories under the temp root that git no longer knows about.
  for d in "$TMPROOT"/grumpy-pr-"$N"-*; do
    [ -e "$d" ] || continue
    rm -rf "$d" || die "cannot delete $d"
    case "$d" in *.out) ;; *) say "deleted unregistered leftover $d"; stray=$((stray + 1));; esac
  done
  say "cleanup PR $N: worktrees removed=$removed (forced=$forced), stray dirs=$stray, outdir(s) deleted"
  exit 0
fi

# ---------------------------------------------------------------- prepare ---
[ "$CMD" = "prepare" ] || die "unknown subcommand: $CMD (prepare | cleanup)"
command -v gh >/dev/null 2>&1 || die "gh not installed"

ORIGIN=$(git remote get-url origin 2>/dev/null) || die "no 'origin' remote in $REPO"
ORIGIN_OR=$(owner_repo "$ORIGIN")
[ -n "$ORIGIN_OR" ] || die "cannot parse owner/repo from origin: $ORIGIN"

# Wrong-repo guard, pass 1: a URL argument must name this repo BEFORE gh runs.
case "$ARG" in *://*)
  ARG_OR=$(owner_repo "$ARG")
  [ "$ARG_OR" = "$ORIGIN_OR" ] || die "wrong repo: PR URL is for $ARG_OR but origin is $ORIGIN_OR — run the review in a checkout of $ARG_OR (pull/$N/head here would be a different, real PR)"
esac

VIEW=$(gh pr view "$N" -R "$ORIGIN_OR" --json title,body,baseRefName,headRefOid,url 2>&1) || die "gh pr view failed: $VIEW"
if command -v jq >/dev/null 2>&1; then
  TITLE=$(printf '%s' "$VIEW" | jq -r .title)
  BODY=$(printf '%s' "$VIEW" | jq -r .body)
  BASE=$(printf '%s' "$VIEW" | jq -r .baseRefName)
  HEAD_OID=$(printf '%s' "$VIEW" | jq -r .headRefOid)
  URL=$(printf '%s' "$VIEW" | jq -r .url)
else
  # jq-free fallback: gh emits compact single-line JSON; the body is read via
  # a second, plain-text gh call to avoid unescaping it by hand.
  field() { printf '%s' "$VIEW" | sed -nE 's#.*"'"$1"'":"([^"]*)".*#\1#p'; }
  TITLE=$(field title); BASE=$(field baseRefName); HEAD_OID=$(field headRefOid); URL=$(field url)
  BODY=$(gh pr view "$N" -R "$ORIGIN_OR" --json body --template '{{.body}}' 2>/dev/null)
fi
case "$HEAD_OID" in ????????????????????????????????????????) ;; *) die "gh pr view returned no headRefOid: $VIEW";; esac
[ -n "$BASE" ] || die "gh pr view returned no baseRefName"
case "$BASE" in -*|*..*|*' '*) die "refusing suspicious base branch name: $BASE";; esac

# Wrong-repo guard, pass 2: the resolved PR must belong to origin as well.
URL_OR=$(owner_repo "$URL")
[ "$URL_OR" = "$ORIGIN_OR" ] || die "wrong repo: gh resolved PR $N to $URL_OR but origin is $ORIGIN_OR"

OID7=$(printf '%s' "$HEAD_OID" | cut -c1-7)
WORKTREE="$TMPROOT/grumpy-pr-$N-$OID7"
OUTDIR="$WORKTREE.out"

git worktree prune
say "git fetch origin pull/$N/head"
git fetch -q origin "pull/$N/head" || die "fetch of pull/$N/head failed"

if [ -d "$WORKTREE" ]; then
  # Same head already materialized by a crashed earlier round: reuse only if
  # git still owns it AND it sits on the exact OID; anything else is a stray.
  cur=$(command git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)
  if [ "$cur" = "$HEAD_OID" ] && git worktree list --porcelain | grep -qx "worktree $WORKTREE"; then
    say "reusing existing worktree $WORKTREE (already at $OID7)"
  else
    die "stale directory in the way: $WORKTREE — run: pr-worktree.sh cleanup $N"
  fi
else
  say "git worktree add --detach $WORKTREE $HEAD_OID"
  git worktree add -q --detach "$WORKTREE" "$HEAD_OID" || die "worktree add failed (was the PR head force-pushed since gh pr view? re-run prepare)"
fi

ACTUAL=$(command git -C "$WORKTREE" rev-parse HEAD) || die "rev-parse in worktree failed"
[ "$ACTUAL" = "$HEAD_OID" ] || die "worktree HEAD $ACTUAL != PR head $HEAD_OID — review is void"

say "git fetch origin $BASE"
git fetch -q origin "$BASE" || die "fetch of base $BASE failed"
MERGE_BASE=$(git merge-base "origin/$BASE" "$HEAD_OID") || die "merge-base origin/$BASE $HEAD_OID failed"

mkdir -p "$OUTDIR" || die "cannot create outdir $OUTDIR"
{ printf '# %s\n\n%s\n' "$TITLE" "$BODY"; } >"$OUTDIR/pr-body.md"
if gh pr diff "$N" -R "$ORIGIN_OR" >"$OUTDIR/diff.patch" 2>"$OUTDIR/diff.err" && [ -s "$OUTDIR/diff.patch" ]; then
  DIFF_SOURCE="gh pr diff"
else
  say "gh pr diff failed ($(head -c 200 "$OUTDIR/diff.err" | tr '\n' ' ')); falling back to git diff $MERGE_BASE..$HEAD_OID"
  command git -C "$WORKTREE" diff -M "$MERGE_BASE..HEAD" >"$OUTDIR/diff.patch" || die "fallback git diff failed"
  DIFF_SOURCE="git diff (gh pr diff failed)"
fi
rm -f "$OUTDIR/diff.err"
DIFF_LINES=$(wc -l <"$OUTDIR/diff.patch" | tr -cd '0-9')

printf '{"pr":%s,"url":"%s","title":"%s","worktree":"%s","outdir":"%s","head_oid":"%s","base":"%s","merge_base":"%s","diff_lines":%s,"diff_source":"%s","claims":"%s"}\n' \
  "$N" "$(json_str "$URL")" "$(json_str "$TITLE")" "$(json_str "$WORKTREE")" "$(json_str "$OUTDIR")" \
  "$HEAD_OID" "$(json_str "$BASE")" "$MERGE_BASE" "${DIFF_LINES:-0}" "$(json_str "$DIFF_SOURCE")" "$(json_str "$OUTDIR/pr-body.md")"
