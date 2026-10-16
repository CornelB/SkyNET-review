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
  make_repo "$REPO"; commit_change "$REPO"
  run prep prepare
  [ "$status" -eq 0 ]
  d=$(field run_dir)
  for lens in simplicity functionality security maintainability; do
    f="$d/prompts/$lens.md"
    [ -f "$f" ]
    head -n 1 "$f" | grep -qx "# Lens: $lens"
    grep -q '^## Output contract' "$f"
    grep -qx "Worktree: $REPO (the operator's checkout, in place)" "$f"
    grep -q "^Diff: $d/diff.patch$" "$f"
    # Every lens and seat gets the guard rules with its scope.
    grep -q '^Guards: hooks deny some commands' "$f"
    # The scope block comes after the lens text.
    [ "$(grep -n '^## Scope' "$f" | cut -d: -f1)" -gt "$(grep -n '^## Output contract' "$f" | cut -d: -f1)" ]
  done
  # The simplicity lens carries the vendored Ponytail text and its attribution.
  grep -q 'BEGIN vendored: Ponytail' "$d/prompts/simplicity.md"
  grep -q 'Dietrich Gebert, MIT' "$d/prompts/simplicity.md"
}

@test "nothing named: the current branch against the default branch" {
  make_repo "$REPO"; commit_change "$REPO"
  printf 'more\n' >>"$REPO/a.txt"; git -C "$REPO" commit -qam more
  run prep prepare
  [ "$status" -eq 0 ]
  [ "$(field kind)" = branch ]
  [ "$(field target)" = feature ]
  [ "$(field base)" = main ]
  [ "$(field merge_base)" = "$(git -C "$REPO" rev-parse main)" ]
  [ "$(field changed_lines)" = 4 ]
}

@test "uncommitted changes stay out of the scope and are named" {
  make_repo "$REPO"; commit_change "$REPO"
  printf 'dirty\n' >>"$REPO/a.txt"; printf 'new\n' >"$REPO/b.txt"
  run prep prepare
  [ "$status" -eq 0 ]
  d=$(field run_dir)
  ! grep -q 'dirty\|new' "$d/diff.patch"
  grep -q '^Note: The checkout has uncommitted changes' "$d/scope.md"
}

@test "a named branch that is not checked out is read at its head" {
  make_repo "$REPO"; commit_change "$REPO"; git -C "$REPO" checkout -q main
  run prep prepare feature
  [ "$status" -eq 0 ]
  [ "$(field head)" = "$(git -C "$REPO" rev-parse feature)" ]
  grep -q '^Note: The checkout is NOT at the branch head' "$(field run_dir)/scope.md"
}

@test "a branch with nothing beyond the default branch fails loudly" {
  make_repo "$REPO"
  run prep prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"nothing committed on feature that main does not have"* ]]
  [ -z "$(ls "$SCRATCH_REAL/review-council")" ]
}

@test "working-tree targets no longer exist" {
  make_repo "$REPO"; commit_change "$REPO"
  for t in uncommitted staged a.txt; do
    run prep prepare "$t"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot resolve target: $t (PR number or URL, or a branch)"* ]]
  done
}

@test "run id, run.json, status.json and the run index" {
  make_repo "$REPO"; commit_change "$REPO"
  run prep -M tribunal prepare
  d=$(field run_dir)
  [[ "$(basename "$d")" == review-feature-* ]]
  [ "$d" = "$SCRATCH_REAL/review-council/$(basename "$d")" ]
  grep -q '"mode":"tribunal","state":"prepared"' "$d/status.json"
  grep -qx "$d" "$XDG_STATE_HOME/review-council/runs.txt"
}

@test "a runs root inside the repository is refused" {
  make_repo "$REPO"; commit_change "$REPO"
  run prep -d "$REPO/scratch" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"inside the repository"* ]]
  [ ! -e "$REPO/scratch" ]
}

@test "unknown target fails loudly" {
  make_repo "$REPO"
  run prep prepare no-such-thing
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot resolve target"* ]]
}

@test "two runs in the same second get distinct run directories" {
  make_repo "$REPO"; commit_change "$REPO"
  run prep prepare; d1=$(field run_dir)
  run prep prepare; d2=$(field run_dir)
  [ -n "$d1" ] && [ -n "$d2" ]
  [ "$d1" != "$d2" ]
}

@test "a runs root inside the repository through a symlink is refused" {
  make_repo "$REPO"; commit_change "$REPO"
  ln -s "$REPO" "$BATS_TEST_TMPDIR/link"
  run prep -d "$BATS_TEST_TMPDIR/link" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"inside the repository"* ]]
  [ ! -e "$REPO/review-council" ]
}
