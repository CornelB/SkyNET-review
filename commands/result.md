---
description: List review-council runs, print a run's report (or the seat reports so far while a tribunal runs), or cancel a running tribunal.
argument-hint: "[list | <run-id> | cancel <run-id>]"
allowed-tools: Read, Bash(bash */review-council/scripts/runs.sh *)
---

Manage review-council runs.

- `$ARGUMENTS` empty or `list`: list runs.
- `$ARGUMENTS` is `cancel <run-id>`: cancel that run.
- Otherwise `$ARGUMENTS` is a run id: show it.

## List

```
bash ${CLAUDE_PLUGIN_ROOT}/scripts/runs.sh list
```

One line per run, newest first: `<id>|<target>|<mode>|<state>|<done>/<total>|<run-dir>`. Show it as a table (id, target, mode, state, seats done/total). No output: say there are no runs and that `/review-council:review` starts one.

## Show

```
bash ${CLAUDE_PLUGIN_ROOT}/scripts/runs.sh show <run-id>
```

- `report|<path>`: Read that file and print it verbatim.
- Otherwise the first line is `state|<state>|<done>/<total>`, then one `<lens>|<seat>|<status>|<detail>|<report-path>` line per process so far. Print the state line, then for every `ok` line Read the report and print it under a `## <lens> / <seat>` heading, verbatim. List the other lines with their status and detail. Do not synthesize: that is `/review-council:review`'s job when the run ends.
- Exit 1: print its stderr line.

## Cancel

```
bash ${CLAUDE_PLUGIN_ROOT}/scripts/runs.sh cancel <run-id>
```

Relay its output line verbatim.
