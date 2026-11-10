#!/usr/bin/env bats
# Every script's -h prints its whole header comment, however long it grows.

load test_helper

@test "-h prints each script's header through its last comment line" {
  for s in pr-worktree prepare-run run-tribunal; do
    f="$SCRIPTS/$s.sh"
    last=$(awk 'NR>1 && !/^#/{exit} NR>1' "$f" | tail -n 1)
    [ "$last" = "$(sed -n '/^set -u/q; /^#/p' "$f" | tail -n 1)" ]
    run "$HOST_BASH" "$f" -h
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "$last" ]
    [ "${lines[0]}" = "$(sed -n 2p "$f")" ]
  done
}
