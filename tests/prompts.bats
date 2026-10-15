#!/usr/bin/env bats
# Run preparation: scope resolution and prompt assembly.

load test_helper

prep() { "$HOST_BASH" "$SCRIPTS/prepare-run.sh" -C "$REPO" "$@"; }
field() { sed -nE 's/.*"'"$1"'":"?([^",]*)"?[,}].*/\1/p' <<<"$output"; }

setup() {
  setup_env
  # Physical path, as git reports it (macOS /var -> /private/var).
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd -P)
}

@test "every lens prompt is the lens file followed by the scope block" {
  make_repo "$REPO"; printf 'one\nTWO\n' >"$REPO/a.txt"
  run prep prepare uncommitted
  [ "$status" -eq 0 ]
  d=$(field run_dir)
  for lens in simplicity functionality security maintainability; do
    f="$d/prompts/$lens.md"
    [ -f "$f" ]
    head -n 1 "$f" | grep -qx "# Lens: $lens"
    grep -q '^## Output contract' "$f"
    grep -qx "Worktree: $REPO (the operator's checkout, in place)" "$f"
    grep -q "^Diff: $d/diff.patch$" "$f"
    # The scope block comes after the lens text.
    [ "$(grep -n '^## Scope' "$f" | cut -d: -f1)" -gt "$(grep -n '^## Output contract' "$f" | cut -d: -f1)" ]
  done
  # The simplicity lens carries the vendored Ponytail text and its attribution.
  grep -q 'BEGIN vendored: Ponytail' "$d/prompts/simplicity.md"
  grep -q 'Dietrich Gebert, MIT' "$d/prompts/simplicity.md"
}

@test "uncommitted: diff includes untracked files, changed lines counted" {
  make_repo "$REPO"; printf 'one\nTWO\n' >"$REPO/a.txt"; printf 'new\n' >"$REPO/b.txt"
  run prep prepare uncommitted
  [ "$status" -eq 0 ]
  [ "$(field kind)" = uncommitted ]
  [ "$(field changed_lines)" = 3 ]
  d=$(field run_dir)
  grep -q '^+new$' "$d/diff.patch"
  # Nothing was added to the index.
  [ -z "$(git -C "$REPO" diff --cached --name-only)" ]
}

@test "nothing named, clean tree: the last commit" {
  make_repo "$REPO"; printf 'three\n' >>"$REPO/a.txt"; git -C "$REPO" commit -qam second
  run prep prepare
  [ "$status" -eq 0 ]
  [ "$(field kind)" = last-commit ]
  [ "$(field changed_lines)" = 1 ]
}

@test "nothing named, dirty tree: uncommitted" {
  make_repo "$REPO"; printf 'x\n' >>"$REPO/a.txt"
  run prep prepare
  [ "$(field kind)" = uncommitted ]
}

@test "staged: only the index" {
  make_repo "$REPO"; printf 'x\n' >>"$REPO/a.txt"; git -C "$REPO" add a.txt; printf 'y\n' >>"$REPO/a.txt"
  run prep prepare staged
  [ "$(field kind)" = staged ]
  [ "$(field changed_lines)" = 1 ]
}

@test "path target with no diff counts the file's lines" {
  make_repo "$REPO"
  run prep prepare "$REPO/a.txt"
  [ "$status" -eq 0 ]
  [ "$(field kind)" = path ]
  [ "$(field changed_lines)" = 2 ]
}

@test "run id, run.json, status.json and the run index" {
  make_repo "$REPO"; printf 'x\n' >>"$REPO/a.txt"
  run prep -M tribunal prepare uncommitted
  d=$(field run_dir)
  [[ "$(basename "$d")" == review-uncommitted-* ]]
  [ "$d" = "$CLAUDE_SCRATCHPAD/review-council/$(basename "$d")" ]
  grep -q '"mode":"tribunal","state":"prepared"' "$d/status.json"
  grep -qx "$d" "$XDG_STATE_HOME/review-council/runs.txt"
}

@test "--run-dir inside the repository is refused" {
  make_repo "$REPO"; printf 'x\n' >>"$REPO/a.txt"
  run prep -r "$REPO/review" prepare uncommitted
  [ "$status" -eq 1 ]
  [[ "$output" == *"inside the repository"* ]]
  [ ! -e "$REPO/review" ]
}

@test "unknown target fails loudly" {
  make_repo "$REPO"
  run prep prepare no-such-thing
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot resolve target"* ]]
}

@test "two runs in the same second get distinct run directories" {
  make_repo "$REPO"; printf 'x\n' >>"$REPO/a.txt"
  run prep prepare uncommitted; d1=$(field run_dir)
  run prep prepare uncommitted; d2=$(field run_dir)
  [ -n "$d1" ] && [ -n "$d2" ]
  [ "$d1" != "$d2" ]
}

@test "--run-dir inside the repository through a symlink is refused" {
  make_repo "$REPO"; printf 'x\n' >>"$REPO/a.txt"
  ln -s "$REPO" "$BATS_TEST_TMPDIR/link"
  run prep -r "$BATS_TEST_TMPDIR/link/review" prepare uncommitted
  [ "$status" -eq 1 ]
  [[ "$output" == *"inside the repository"* ]]
  [ ! -e "$REPO/review" ]
}
