# review-council

A council of specialised reviewers for AI-authored code. One command, four parallel seats, one merged report.

| Seat | What it does |
|------|--------------|
| `grumpy` | Core pass: correctness, performance, maintainability. Suspicious by default, no benefit of the doubt. |
| `security` | Read-only security audit. Reports only findings above 80% confidence with a concrete attack path. |
| `hallucination` | Proves the code is grounded: every PR claim traced to a line, every API, package, flag and path shown to exist, every test shown to fail when the logic breaks. |
| `simplicity` | The [Ponytail](https://github.com/DietrichGebert/ponytail) review: bug, risk, scale, missing test, speed, and what should not exist. |

Findings seen by two or more seats are `CONFIRMED`. A single-seat finding is verified against the code or marked `UNCORROBORATED`. The final verdict comes only from findings that survived verification.

`--tribunal` adds external seats (codex, gemini/antigravity, claude, grok) through a version-controlled launcher with no approval bypasses.

## Install

```
/plugin marketplace add CornelB/AI-review-council
```
```
/plugin install review-council@cornelb-plugins
```

For a prompt-free multi-round review add once to `~/.claude/settings.json` `permissions.allow`:

```
"Bash(bash */review-council/scripts/pr-worktree.sh *)",
"Bash(bash */review-council/scripts/tribunal.sh *)"
```

## Use

```
/review-council:review 123
/review-council:review https://github.com/owner/repo/pull/123 --tribunal
/review-council:review uncommitted --seats=security,hallucination
/review-council:review feature/branch
```

PR targets are materialised in a detached worktree pinned to the PR head OID under the scratchpad, reviewed there, and removed afterwards. The repository is never touched: no branches, no refs, no files, no PR comments.

## Layout

- `commands/review.md` - the orchestrator: parses the target, dispatches the seats in parallel, synthesises.
- `agents/*-reviewer.md` - one seat each.
- `skills/review-engine/SKILL.md` - hard constraints, PR worktree setup and cleanup, tribunal mode, report format.
- `scripts/pr-worktree.sh` - materialise and tear down the exact tree under review.
- `scripts/tribunal.sh` - launcher for the external seats; every CLI flag lives here.

## Credits

- The `simplicity` seat is `skills/ponytail-review/SKILL.md` from [Ponytail](https://github.com/DietrichGebert/ponytail) by Dietrich Gebert, MIT.
- The engine and the `grumpy` seat grew out of the grumpy-review skill.
- Shape inspired by [claude-council](https://github.com/hex/claude-council).

## License

MIT.
