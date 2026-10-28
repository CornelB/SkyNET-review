# review-board

One command that judges a change from four angles and returns one report. It runs locally with fresh-context Claude subagents, or as a tribunal of external AI coding harnesses that read the tree. Reports only: it changes no code, posts no comments, creates no branches and writes nothing inside the repository.

## Lenses

In priority order. Each lens is one self-contained prompt in `prompts/lenses/`; the same text goes to the local subagent and to every seat.

| Lens | What it judges |
|------|----------------|
| `simplicity` | KISS: what the change can lose and still do its job. Dead code, yagni, hardening for load the repo does not have, wrappers, duplication. Never asks for more code. |
| `functionality` | Grumpy, no benefit of the doubt: business logic, edge cases, requirements, every PR and commit claim marked VERIFIED / FALSE / UNPROVABLE, every symbol, package, flag and path shown to exist, tests that really fail. |
| `security` | Read-only audit. Findings only above 80% confidence with a concrete attack path. |
| `maintainability` | Readability, naming against the repo's own conventions, docs and comments that describe what the code does. |

## Modes

Exclusive; pick one per run.

- **local** (default): one subagent per lens, in parallel, with only its lens prompt and the scope. Model: Fable at effort low; Opus xhigh when the desktop app reports the weekly Fable usage above 80%. The downgrade is announced before launch and named in the report header. `--effort=` overrides the effort.
- **tribunal** (`--tribunal`): every available seat runs every lens prompt in the worktree, detached in the background. Seats are blind to each other. Zero available seats aborts before anything runs.

Findings from two or more sources are `CONFIRMED`. A single-source finding is verified against the code or marked `UNCORROBORATED`. The verdict comes only from findings that survived verification. Claude sources count as one voice.

## Seats

Harnesses only, each in its own read-only or plan sandbox, with no approval bypass and no passthrough flags. The diff leaves the machine only through a harness you installed.

| Seat | Available when |
|------|----------------|
| `codex` | `codex` on PATH. GPT-6 Astra low; GPT-6.1 Sol xhigh when the weekly Codex usage is above 60% |
| `antigravity` | `agy` on PATH (merges a pinned `read_file(*)` allow-list into its settings on first use) |
| `grok` | `grok` on PATH |
| `claude-cli` | `claude` on PATH and logged in. Fable medium; Opus xhigh when the weekly Fable usage is above 80% |
| `kimi-cli` | `kimi` and `jq` on PATH |
| `cursor-cli` | `cursor-agent` on PATH |
| `codex-oss` | `codex` and `ollama` on PATH and `OLLAMA_REVIEWER_MODEL` set, and the diff fits the model's context; its four runs go one at a time |

Wall-clock cap per process: 600 s up to 2000 changed lines, 1200 s up to 6000, 1800 s beyond. A timeout that was still producing output gets one retry at twice the cap, once per seat.

## Install (local)

```bash
claude plugin marketplace add /path/to/SkyNET-review
claude plugin install review-board@review-board-local
```

From GitHub it installs through [SkyNET-marketplace](https://github.com/CornelB/SkyNET-marketplace) as `SkyNET-review@SkyNET-marketplace`.

A tribunal spans turns. For a prompt-free run add once to `~/.claude/settings.json` `permissions.allow`:

```
"Bash(bash */review-board/scripts/prepare-run.sh *)",
"Bash(bash */review-board/scripts/run-tribunal.sh *)",
"Bash(bash */review-board/scripts/runs.sh *)"
```

## Use

```
/review-board:review 123
/review-board:review https://github.com/owner/repo/pull/123 --tribunal
/review-board:review
/review-board:review feature/branch --tribunal
/review-board:review feature/branch --effort=high
/review-board:status
/review-board:result
/review-board:result review-pr-123-20261015-101500
/review-board:result cancel review-pr-123-20261015-101500
```

Targets: PR number or URL, or a branch. Nothing named: the current branch, that is, the commits on it that the default branch does not have. Uncommitted changes are never in scope. A PR is reviewed in a detached worktree pinned to the PR head OID, with an explicit `<merge-base>..<head>` range, and the worktree is removed at the end.

`/review-board:status` lists every seat as available or disabled with the reason, and the Claude and codex models that apply now. `/review-board:result` lists runs newest first, prints a run's report (or the seat reports so far while a tribunal runs), or cancels a running tribunal.

While a tribunal runs, a `REVIEW` band above the prompt shows how many lens/seat processes finished (`2 of 16`), a line that fills with them, the run's clock and the latest process to end. When the run ends the band says how many reports came back ok for 20 seconds. The band is a Claude Code mod (`mods/review-band/`, loaded through `hooks/hooks.json`); it reads the run's `status.json` once a second and draws nothing when no tribunal is live.

## Environment

| Variable | Effect |
|----------|--------|
| `OLLAMA_REVIEWER_MODEL` | Enables the `codex-oss` seat with this local ollama model. |
| `CURSOR_CLI_MODEL`, `KIMI_CLI_MODEL` | Model for those seats; unset uses the CLI's default. |
| `CLAUDE_SCRATCHPAD`, `TMPDIR` | Parent of the default run directory, `<dir>/review-board/review-<target>-<ts>/`. |
| `XDG_STATE_HOME` | Where the run index lives (`review-board/runs.txt`, default `~/.local/state`). |
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
- `mods/review-band/` - the progress band above the prompt. `bun test` in that folder runs its tests.
- `tests/` - bats suite with fake CLIs. `bats tests` and `shellcheck` run in CI on every push.

## Credits

- The engine and the `functionality` and `security` lenses grew out of the grumpy-review skill.
- Shape (seat contract, discovery, status and result commands, synthesis calibration) inspired by [claude-council](https://github.com/hex/claude-council).

## License

MIT.
