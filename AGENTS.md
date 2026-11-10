# AGENTS.md

- Layout and checks: `README.md`, section listing the folders. It names the test, shellcheck and band type-check commands.
- The band's type-check needs `types/claude-code.d.ts` from Claude Code's plugin-authoring skill. Load that skill to get its path; do not search the disk for it.
- Design and run layout: `docs/DESIGN.md`. Hard constraints and seat contract: `skills/review-engine/SKILL.md`.
- A change to the band or a run's status applies to tribunal and local mode alike, through the same code.
