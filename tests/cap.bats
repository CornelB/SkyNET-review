#!/usr/bin/env bats
# Cap sizing, changed-line counting and the model rules.

load test_helper

lib() { . "$SCRIPTS/lib/common.sh"; "$@"; }

@test "cap: 600 s up to 2000 changed lines" {
  run lib rc_cap_for_lines 0;    [ "$output" = 600 ]
  run lib rc_cap_for_lines 2000; [ "$output" = 600 ]
}

@test "cap: 1200 s up to 6000" {
  run lib rc_cap_for_lines 2001; [ "$output" = 1200 ]
  run lib rc_cap_for_lines 6000; [ "$output" = 1200 ]
}

@test "cap: 1800 s beyond 6000" {
  run lib rc_cap_for_lines 6001;   [ "$output" = 1800 ]
  run lib rc_cap_for_lines 900000; [ "$output" = 1800 ]
}

@test "claude rule: Fable low local, Fable high tribunal, Opus xhigh above 80%" {
  run lib rc_model_rule local;          [ "$output" = "fable low" ]
  run lib rc_model_rule local 80;       [ "$output" = "fable low" ]
  run lib rc_model_rule local 81;       [ "$output" = "opus xhigh" ]
  run lib rc_model_rule tribunal;       [ "$output" = "fable high" ]
  run lib rc_model_rule tribunal 80;    [ "$output" = "fable high" ]
  run lib rc_model_rule tribunal 93;    [ "$output" = "opus xhigh" ]
}

@test "codex rule: Astra low up to 60%, Sol xhigh above, Astra when unknown" {
  run lib rc_codex_rule;    [ "$output" = "gpt-6-astra low" ]
  run lib rc_codex_rule 60; [ "$output" = "gpt-6-astra low" ]
  run lib rc_codex_rule 61; [ "$output" = "gpt-6.1-sol xhigh" ]
}

@test "changed lines: headers excluded, a removed '-- ' line still counts" {
  cat >"$BATS_TEST_TMPDIR/d.patch" <<'P'
diff --git a/x.sql b/x.sql
index 1111111..2222222 100644
--- a/x.sql
+++ b/x.sql
@@ -1,3 +1,3 @@
 keep
--- a sql comment
+-- a new comment
+added
P
  run lib rc_changed_lines "$BATS_TEST_TMPDIR/d.patch"
  [ "$output" = 3 ]
}

@test "changed lines: missing file is 0" {
  run lib rc_changed_lines "$BATS_TEST_TMPDIR/none.patch"
  [ "$output" = 0 ]
}

@test "launcher sizes the cap from run.json changed_lines" {
  fake_codex
  d=$(prepared_run)
  sed -i.bak -E 's/"changed_lines":[0-9]+/"changed_lines":4500/' "$d/run.json"
  run "$HOST_BASH" "$SCRIPTS/run-tribunal.sh" run -s codex "$d"
  [ "$status" -eq 0 ]
  grep -q '"cap":1200' "$d/status.json"
}
