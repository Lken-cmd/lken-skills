# lk-skills

Agent skills for Claude Code and compatible agents, installable with the `skills` CLI.

| skill | what it does |
|---|---|
| `orchestrate` | Drives a large, already-designed feature to completion: one fresh subagent per phase, review after each phase or once at the end, a state file committed to an `orchestration-state` branch so a run survives session boundaries. |
| `claude-usage` | Reports subscription usage limits and the session's context size as JSON, with a percentage when given the context window. |
| `cleanup` | End-of-session cleanup: merged branches, worktrees, scratch files, dead exclude entries, the memory index, an ADR index, and comment or text findings on the branch. Deletes what is provably obsolete, asks about the rest. |

## Install

```
npx skills add lken-cmd/lk-skills -g -a claude-code
npx skills add lken-cmd/lk-skills --skill orchestrate -g
npx skills update
```

`orchestrate` expects `/code-review` and `/claude-usage` to be installed as well; `/handoff` and
`/grill-with-docs` are referenced but optional. `/code-review`, `/handoff` and `/grill-with-docs` all
come from Matt Pocock's [mattpocock/skills](https://github.com/mattpocock/skills)
(`npx skills add mattpocock/skills --skill code-review -g`). `claude-usage` and `cleanup` need
PowerShell 7 (`pwsh`).
