---
description: Show which review-council tribunal seats are available or disabled (and why), and which lens model rule applies right now. Read-only.
argument-hint: ""
allowed-tools: ToolSearch, mcp__ccd_session_mgmt__get_usage, Bash(bash */review-council/scripts/run-tribunal.sh discover*)
---

Read-only. Change nothing, launch nothing.

1. Run:

```
bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-tribunal.sh discover
```

It prints one `<seat>|available|<model, sandbox>` or `<seat>|disabled|<reason>` line per seat. Show one line per seat, in that order:

```
codex        available (default model, xhigh, read-only sandbox)
kimi-cli     disabled (kimi not on PATH)
```

2. Lens model rule right now. Load `mcp__ccd_session_mgmt__get_usage` with ToolSearch and call it. Then print:

```
Lens model: under 100 changed lines -> Opus xhigh; 100 and above -> Fable medium
Fable weekly usage: <N>% -> <Fable medium | downgraded to Opus xhigh (>= 85%)>
```

When the tool does not exist (terminal `claude`, `claude -p`), print `Fable weekly usage: unknown (no get_usage tool) -> Fable medium` instead.

Nothing else: no advice, no summary.
