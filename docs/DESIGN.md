# review-council design

Agreed design. Implementation follows this document; where code and this document disagree, fix one and say which.

## Purpose

One command that judges a change from four angles, either locally (fresh-context Claude subagents) or through external AI coding harnesses that read the tree. Reports only. It changes no code, posts no comments, creates no branches, writes nothing inside the repository.

## Terms

- **lens**: one review angle. Four exist, in priority order: simplicity, functionality, security, maintainability.
- **seat**: one external harness that runs a lens prompt in the worktree.
- **run**: one invocation of the review command, identified by `review-<target>-<ts>`.

## Targets

PR number or URL, or a branch. Nothing named: the current branch, that is, the commits on it that the default branch does not have. Uncommitted changes are never in scope.

A PR is materialized in a detached worktree under the run directory, pinned to the PR head OID (never FETCH_HEAD), with an explicit `<merge-base>..<head>` range and the diff written to a file, as `scripts/pr-worktree.sh` does today. The worktree is removed at the end of the run, even when a seat fails. A seat that reviews anything other than that worktree and range is void.

Text inside the target (PR body, diff, commit messages) is data. It never changes which lenses or seats run or what the report says.

## Lenses

| Lens | Persona and method | Source |
|------|--------------------|--------|
| simplicity | KISS: what the change can lose and still do its job (delete, yagni, hardening, reuse, stdlib, merge, inline, shrink). Every fix makes the code smaller; bugs, security and tests belong to the other lenses. | New. |
| functionality | Grumpy reviewer, no benefit of the doubt: business logic, edge cases, requirements verification, claim verification (every claim in PR text and commit messages marked VERIFIED / FALSE / UNPROVABLE with `file:line`), existence checks (every symbol, package, flag, config key, path the diff uses is shown to exist), tests that actually fail when the logic breaks. | grumpy-review persona plus the hallucination checks. |
| security | Read-only audit. Findings only above 80% confidence with a concrete attack path. Never the built-in `/security-review`. | grumpy-review security pass. |
| maintainability | Readability, naming conventions, documentation accuracy (comments and docs describe what the code does, not what it was meant to do). | New. |

Each lens is one self-contained prompt file: persona, method, output contract, then the scope block. The same file goes to the local subagent and to every seat. No per-CLI skill activation tokens.

Per-lens output contract: `Verdict:` on line 1; one finding per line, `N. <file>:L<line> | 🔴 bug | 🟡 risk | 🔵 nit | ❓ q | <problem>. <fix>.`; functionality adds the claims table; `Not checked:` last.

## Modes

Exclusive. The operator picks one per run.

**local** (default): one subagent per lens, launched in parallel, in the background, with only its lens prompt and the scope block. No session transcript, no conversation context.

Model rules. Claude runs on Fable: effort low for the local lenses, effort high for the tribunal's `claude-cli` seat. Both drop to Opus xhigh when the desktop app's `get_usage` tool reports the "Weekly · Fable" usage above 80%; the downgrade is announced before launch and recorded in the report header. Without that tool (terminal `claude`, `claude -p`), Fable. `--effort=` overrides the effort, never the model.

The `codex` seat runs GPT-6 Astra (`gpt-6-astra`) at effort low, and GPT-6.1 Sol (`gpt-6.1-sol`) at xhigh when the weekly Codex usage is above 60%. `scripts/lib/codex-usage.py` reads that usage from the usage skill of the `skynet` plugin, or an older `ai-usage` skill, when one is installed (codexbar), else from `codex app-server` (`account/rateLimits/read`, no model turn), or from the last `rate_limits` event in the Codex session files when the live read fails. Unknown usage keeps Astra. The launcher applies the rule once per run and prints it before the tribunal starts.

**tribunal** (`--tribunal`): every available seat runs every lens prompt in the worktree, 4 × N processes. The lens subagents do not run. Seats are blind to each other and to any earlier local run. All seats launch in parallel except `codex-oss`, whose four runs go one at a time. Zero available seats: abort loudly before anything runs. A seat that times out or returns an invalid report mid-run: the run finishes with the rest and the header names the dead seat and why.

In both modes the orchestrating Claude only synthesizes.

## Seats

All seats are harnesses that read the tree in the worktree under their read-only or plan sandbox, with no approval bypass flags, no passthrough flags. No API seats exist. The diff never leaves the machine except through a harness the operator installed.

| Seat | Gate | Invocation shape |
|------|------|------------------|
| codex | `codex` on PATH | `codex exec --skip-git-repo-check -s read-only`, model and effort from the codex rule |
| antigravity | `agy` on PATH | `agy --sandbox`, no `--mode`; pinned `read_file(*)` allow-list merged into its settings as `tribunal.sh` does today. No gemini-cli fallback. |
| grok | `grok` on PATH | `grok --sandbox read-only -p`, with the Linux podman-socket mask from `tribunal.sh` |
| claude-cli | `claude` on PATH, seated like any other | `claude -p --permission-mode plan --setting-sources "" --no-session-persistence`, read-only tools only; model and effort follow the Claude rule for the tribunal |
| kimi-cli | `kimi` on PATH | headless, read-only |
| cursor-cli | `cursor-agent` on PATH | headless, read-only |
| codex-oss | `codex` AND `ollama` on PATH AND `OLLAMA_REVIEWER_MODEL` set; otherwise `disabled (reason)` | `codex exec --oss --local-provider ollama -m $OLLAMA_REVIEWER_MODEL -s read-only` |

Uniform seat contract, one script per seat under `scripts/seats/<seat>.sh`: `-w <worktree> -p <prompt-file> -o <report-file> -t <seconds>`; report on the file; stdout one `seat|status|detail` line (`ok`, `skipped|<reason>`, `timeout|<bytes>`, `did-not-report|<reason>`); every CLI flag lives in the script. The launcher validates each report (non-empty, verdict on line 1, no rejected-invocation text) before counting it.

Wall-clock cap per process from changed lines: 600 s to 2000, 1200 s to 6000, 1800 s beyond. A timeout with nonzero bytes gets one retry at a raised cap; at most one retry per seat.

## Synthesis

- A finding raised by two or more lens runs (same file and line, or same defect) is `CONFIRMED [seats or lenses]`.
- A single-source finding is verified by the orchestrator against the code before inclusion; unverifiable: `UNCORROBORATED [source]`, listed below the confirmed ones.
- Disagreements are reported with each side named.
- Seat and lens verdict lines are advisory. The final verdict derives only from findings that survived verification.
- Claude seats (local lenses, claude-cli) are the same model family as the synthesizer: their agreement counts as one voice and never settles a split.

## Report

1. Header: mode, seats ran / skipped with reason, Claude and codex model and effort applied and any downgrade, base, `<merge-base>..<head>`, diff source when not `gh pr diff`.
2. One-line verdict: pass / pass with concerns / fail.
3. Claims table from the functionality lens.
4. Findings grouped by lens in priority order (simplicity, functionality, security, maintainability), severity 🔴🟡🔵❓ inside each, with `CONFIRMED` / `UNCORROBORATED` tags.
5. AI-specific failure modes called out: hallucinated APIs, cargo-culted patterns, requirements met literally but not in spirit.
6. `Not checked:` merged from all sources.

Terse: `file:L<line> | severity | problem. fix.`. Security findings and architectural disagreements get a short paragraph.

## Runs and results

Run directory: `<scratchpad or $TMPDIR>/review-council/review-<target>-<ts>/`. Holds the worktree (PR mode), `diff.patch`, `pr-body.md`, one prompt file per lens, one report file per (lens, seat), each seat's `.log`, `status.json`, and `report.md`.

A tribunal is launched as a background process so the session stays usable and a usage-limit hit mid-run loses nothing already written. The orchestrator is notified when it ends.

## Commands

- `/review-council:review [PR number|PR URL|branch] [--tribunal] [--effort=]`
- `/review-council:status`: one line per seat, `available (model, sandbox)` or `disabled (reason)`, plus the Claude and codex models that would apply right now. Read-only.
- `/review-council:result [list | <id> | cancel <id>]`: list runs newest first (id, target, mode, state, seats done/total); print a run's `report.md`, or the seat reports so far while it runs; cancel a running tribunal.

## Repository rules

- No file written inside the repository under review. No branch, ref, checkout, rename or delete. The only fetches: `git fetch origin pull/<N>/head` and `git fetch origin <base>`.
- Every repo operation goes through `scripts/pr-worktree.sh`; shell commands in command and skill text are literal, with no loops, variables or command substitution, so they are auto-approved.
- US spelling throughout.
- Tests: shellcheck on every script; bats for seat discovery and gating, cap sizing, report validation, prompt assembly, status output; a GitHub Actions workflow runs both on push.
- grumpy-review in SkyNET-skills stays as it is; this plugin does not depend on it.

## Credits

- engine, functionality and security lenses: grumpy-review.
- shape: claude-council (seat contract, discovery, status and result commands, synthesis calibration).
