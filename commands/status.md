---
description: Show which review-council tribunal seats are available or disabled (and why), and which Claude and codex models apply right now. Read-only.
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
codex        available (gpt-6-astra, low, week 18% (live), read-only sandbox)
kimi-cli     disabled (kimi not on PATH)
```

The codex line already shows the codex rule applied to the weekly Codex usage: GPT-6 Astra low, or GPT-6.1 Sol xhigh above 60%.

2. Claude model rule right now. Load `mcp__ccd_session_mgmt__get_usage` with ToolSearch and call it. Then print:

```
Claude model: local -> Fable low; tribunal claude-cli -> Fable high
Fable weekly usage: <N>% -> <Fable | downgraded to Opus xhigh (> 80%)>
```

When the tool does not exist (terminal `claude`, `claude -p`), print `Fable weekly usage: unknown (no get_usage tool) -> Fable` instead.

Nothing else: no advice, no summary.
