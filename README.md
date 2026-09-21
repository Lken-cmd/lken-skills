# lken-skills

Agent skills for Claude Code and compatible agents, installable with the `skills` CLI.

| skill | what it does |
|---|---|
| `orchestrate` | Drives a large, already-designed feature to completion: one fresh subagent per phase, review after each phase or once at the end, a state file committed to an `orchestration-state` branch so a run survives session boundaries. |
| `claude-usage` | Reports subscription usage limits and the session's context size as JSON, with a percentage when given the context window. |
| `cleanup` | End-of-session cleanup: merged branches, worktrees, scratch files, dead exclude entries, the memory index, an ADR index, and comment or text findings on the branch. Deletes what is provably obsolete, asks about the rest. |

## Install

```
npx skills add Lken-cmd/lken-skills -g -a claude-code
npx skills add Lken-cmd/lken-skills --skill orchestrate -g
npx skills update
```

`orchestrate` invokes `/claude-usage` from this repo and `/mattpocock-skills:code-review`;
`/mattpocock-skills:handoff` and `/mattpocock-skills:grill-with-docs` are referenced but optional.
The three prefixed ones come from Matt Pocock's skills, installed as the `mattpocock-skills`
plugin (`/plugin install mattpocock-skills@claude-plugins-official`) — the prefix is that plugin's,
so adjust it if you install those skills some other way. `claude-usage` and `cleanup` need
PowerShell 7 (`pwsh`).

## AGENTS.md template

[`templates/AGENTS.template.md`](templates/AGENTS.template.md) is the starting `AGENTS.md` for a new
repository: generic, checkable rules only — pointers to where knowledge lives, architecture,
verification, testing, comments, user-facing text, commits, repo hygiene, dependencies, and what a
session leaves behind. It holds only rules true for any project, so a house style such as the
em-dash rule (which `cleanup`'s dash scan needs in order to run at all) is left for each project to
add. Its architecture bullets are derived from
`mattpocock-skills:codebase-design` v1.2.3, except "deepen only the code the current change
touches"; re-derive them when that skill changes. Each project fills in the skeletons (what it is, which documents to
point at, how it is verified, and any design word that carries a domain sense) and grows its own
rules into the same file.

```
curl -o AGENTS.md https://raw.githubusercontent.com/Lken-cmd/lken-skills/main/templates/AGENTS.template.md
```
