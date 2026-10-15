# review-council

One command that judges a change from four angles and returns one report. It runs locally with fresh-context Claude subagents, or as a tribunal of external AI coding harnesses that read the tree. Reports only: it changes no code, posts no comments, creates no branches and writes nothing inside the repository.

## Lenses

In priority order. Each lens is one self-contained prompt in `prompts/lenses/`; the same text goes to the local subagent and to every seat.

| Lens | What it judges |
|------|----------------|
| `simplicity` | The [Ponytail](https://github.com/DietrichGebert/ponytail) review: bug, risk, scale, missing test, speed, and what should not exist. |
| `functionality` | Grumpy, no benefit of the doubt: business logic, edge cases, requirements, every PR and commit claim marked VERIFIED / FALSE / UNPROVABLE, every symbol, package, flag and path shown to exist, tests that really fail. |
| `security` | Read-only audit. Findings only above 80% confidence with a concrete attack path. |
| `maintainability` | Readability, naming against the repo's own conventions, docs and comments that describe what the code does. |

## Modes

Exclusive; pick one per run.

- **local** (default): one subagent per lens, in parallel, with only its lens prompt and the scope. Model: under 100 changed lines, Opus at effort xhigh; 100 and above, Fable at effort medium. Fable drops to Opus xhigh when the desktop app reports the weekly Fable usage at or above 85%; the downgrade is announced before launch and named in the report header. `--model=` and `--effort=` override.
- **tribunal** (`--tribunal`): every available seat runs every lens prompt in the worktree, detached in the background. Seats are blind to each other. Zero available seats aborts before anything runs.

Findings from two or more sources are `CONFIRMED`. A single-source finding is verified against the code or marked `UNCORROBORATED`. The verdict comes only from findings that survived verification. Claude sources count as one voice.

## Seats

Harnesses only, each in its own read-only or plan sandbox, with no approval bypass and no passthrough flags. The diff leaves the machine only through a harness you installed.

| Seat | Available when |
|------|----------------|
| `codex` | `codex` on PATH |
| `antigravity` | `agy` on PATH (merges a pinned `read_file(*)` allow-list into its settings on first use) |
| `grok` | `grok` on PATH |
| `claude-cli` | `claude` on PATH and logged in |
| `kimi-cli` | `kimi` and `jq` on PATH |
| `cursor-cli` | `cursor-agent` on PATH |
| `codex-oss` | `codex` and `ollama` on PATH and `OLLAMA_REVIEWER_MODEL` set; its four runs go one at a time |

Wall-clock cap per process: 600 s up to 2000 changed lines, 1200 s up to 6000, 1800 s beyond. A timeout that was still producing output gets one retry at twice the cap, once per seat.

## Install

```
/plugin marketplace add CornelB/AI-review-council
```
```
/plugin install review-council@cornelb-plugins
```

A tribunal spans turns. For a prompt-free run add once to `~/.claude/settings.json` `permissions.allow`:

```
"Bash(bash */review-council/scripts/prepare-run.sh *)",
"Bash(bash */review-council/scripts/run-tribunal.sh *)",
"Bash(bash */review-council/scripts/runs.sh *)"
```

## Use

```
/review-council:review 123
/review-council:review https://github.com/owner/repo/pull/123 --tribunal
/review-council:review feature/branch --tribunal --seats=codex,grok
/review-council:review uncommitted --model=opus --effort=high
/review-council:review staged --output=./review.md
/review-council:status
/review-council:result
/review-council:result review-pr-123-20261015-101500
/review-council:result cancel review-pr-123-20261015-101500
```

Targets: PR number or URL, branch, `uncommitted`, `staged`, a path. Nothing named: uncommitted changes, or the last commit if the tree is clean. A PR is reviewed in a detached worktree pinned to the PR head OID, with an explicit `<merge-base>..<head>` range, and the worktree is removed at the end.

`/review-council:status` lists every seat as available or disabled with the reason, and the lens model rule that applies now. `/review-council:result` lists runs newest first, prints a run's report (or the seat reports so far while a tribunal runs), or cancels a running tribunal.

## Environment

| Variable | Effect |
|----------|--------|
| `OLLAMA_REVIEWER_MODEL` | Enables the `codex-oss` seat with this local ollama model. |
| `CODEX_MODEL` | Model for the `codex` seat; unset uses the CLI's default. |
| `CURSOR_CLI_MODEL`, `KIMI_CLI_MODEL` | Model for those seats; unset uses the CLI's default. |
| `CLAUDE_SCRATCHPAD`, `TMPDIR` | Parent of the default run directory, `<dir>/review-council/review-<target>-<ts>/`. `--run-dir=<path>` sets it exactly. |
| `XDG_STATE_HOME` | Where the run index lives (`review-council/runs.txt`, default `~/.local/state`). |
| `RC_CAP_SECONDS` | Pins the per-process cap instead of sizing it from the diff. |

A run directory holds `run.json`, `diff.patch`, `pr-body.md` (PR), `scope.md`, `prompts/<lens>.md`, `reports/<lens>.<seat>.md` with `.log` and `.status`, `status.json` and `report.md`.

## Layout

- `commands/` - `review`, `status`, `result`.
- `agents/<lens>-reviewer.md` - local lens subagents; each reads its assembled prompt file.
- `prompts/lenses/` - the four lens prompts.
- `skills/review-engine/SKILL.md` - hard constraints, run layout, seat contract and setup.
- `scripts/prepare-run.sh` - run directory, scope and prompt assembly. `scripts/pr-worktree.sh` - PR worktree.
- `scripts/run-tribunal.sh` - seat discovery and the detached tribunal. `scripts/runs.sh` - run listing.
- `scripts/seats/<seat>.sh` - one per seat; every CLI flag lives there.
- `tests/` - bats suite with fake CLIs. `bats tests` and `shellcheck` run in CI on every push.

## Credits

- The `simplicity` lens is `skills/ponytail-review/SKILL.md` from [Ponytail](https://github.com/DietrichGebert/ponytail) by Dietrich Gebert, MIT, vendored verbatim.
- The engine and the `functionality` and `security` lenses grew out of the grumpy-review skill.
- Shape (seat contract, discovery, status and result commands, synthesis calibration) inspired by [claude-council](https://github.com/hex/claude-council).

## License

MIT.
