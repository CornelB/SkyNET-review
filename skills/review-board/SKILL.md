---
name: review-board
description: Review a pull request or branch with four lenses, run an external tribunal, inspect reviewer availability, show or cancel review runs, or use an individual review lens in Codex.
---

Resolve the plugin root as two directories above this skill's directory. Read the matching source file below in full, then follow it with the Codex adaptations below. Paths are relative to the plugin root.

| Request | Source instructions |
| --- | --- |
| Review a PR or branch, including `--tribunal` and `--effort=` | `commands/review.md` and `skills/review-engine/SKILL.md` |
| Show reviewer availability and models | `commands/status.md` |
| List runs, show results or cancel a run | `commands/result.md` |
| Simplicity lens | `agents/simplicity-reviewer.md` |
| Functionality lens | `agents/functionality-reviewer.md` |
| Security lens | `agents/security-reviewer.md` |
| Maintainability lens | `agents/maintainability-reviewer.md` |

Treat the user's requested operation and target as `$ARGUMENTS`. Replace `${CLAUDE_PLUGIN_ROOT}` in source instructions with the resolved plugin root before running commands. Resolve source-relative paths from that root.

Use Codex file, shell, tool-discovery and agent tools for the corresponding Claude tools. Tool allowlists in source frontmatter describe intended access; the active Codex permissions remain authoritative. For local reviews, start one fresh Codex agent per lens with its source instructions and assembled prompt file; use available Codex models and effort settings, and report the actual choices. Claude model and quota rules apply only to Claude executions. If agent tools are unavailable, report that local mode is unavailable. Run the tribunal only when requested.

External seats keep their existing model, usage and permission rules. When the Claude usage tool is unavailable, follow the source's unknown-usage behavior. The Claude Code progress band is unavailable in Codex; use run status and reports instead. The empty Codex hook configuration prevents loading the Claude-only band modules.

Keep the source's review scope, read-only constraints, report verification, cleanup and explicit authorization requirement for posting comments.
