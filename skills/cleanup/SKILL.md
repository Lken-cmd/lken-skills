---
name: cleanup
description: End-of-session cleanup for a git repository. Surveys stale git artifacts (merged branches, worktrees, scratch and handoff files, dead exclude entries, stray tags), the agent's memory index, an ADR index when the repo keeps one, and the comments and text the current branch adds, then deletes what is provably obsolete, asks about the rest and reports both. Use when the user says "clean up", "tidy up", "session end", "prune branches", "remove stale files", "check the memory", "are the ADRs current", or before handing a branch over or closing a long orchestrated run.
argument-hint: "[what this session created, e.g. branch names or scratch files]"
compatibility: PowerShell 7 (pwsh) and git; gh for pull-request threads.
---

# Cleanup

Leave the repo, the memory and the record the way the next session needs them: nothing stale that
looks current, nothing deleted that someone still needs. When the repo carries its own rules for
session end (an `AGENTS.md` or `CLAUDE.md` at the root), those rules win over the defaults below;
this skill is the procedure for applying them and the report that proves it.

Three verdicts exist and every item gets exactly one:

| verdict | meaning | who decides |
|---|---|---|
| **cleaned** | created by this session and no longer needed, or provably obsolete (a branch merged into the main branch, an exclude entry whose file is gone, an index row without a file) | you |
| **candidate** | might be stale but the evidence is indirect: an unmerged branch, a worktree with changes, a tag, a memory whose fact may have changed, an untracked file this session did not create | the user, via `AskUserQuestion` |
| **left on purpose** | current, or owned by someone else | you, with the reason in the report |

Deleting a candidate without asking is the one failure this skill exists to prevent. Asking about
something already proven obsolete is the second.

## 1. Survey

Run the read-only survey from inside the repo under `pwsh`. The script lives in this skill's folder,
the base directory named when the skill loaded, and it writes nothing:

```powershell
& "<skill folder>\Get-CleanupCandidates.ps1" -MemoryDir "<your memory directory>" | Out-File -Encoding utf8 "<scratchpad>\cleanup-survey.json"
```

The memory directory is the one your system prompt names; omit the parameter and the script derives
it from the repo path, which fails silently for a worktree whose path differs from the session's.
`-BaseRef` names the branch the diff is taken against (`origin/main` by default). Read the JSON once
and work through its sections in the order below. Add whatever the arguments named as this session's
own creations; the script cannot know who created a file.

## 2. Git

- **Branches.** `merged_into_main: true` and no worktree checked out on it: delete with
  `git branch -d`. Everything else is a candidate, including `backup/*` branches and branches whose
  upstream is gone (`upstream_gone`). Never delete a remote branch without the user naming it.
- **Worktrees.** `git worktree prune` always. A worktree this session created and whose tree is
  clean: `git worktree remove` then prune. Any other worktree, or one with changes, is a candidate.
  The main worktree is never touched.
- **Tags.** Never create or delete a tag on your own; a build that stamps its version from
  `git describe` is poisoned by a stray one. Existing non-version tags (`non_version_tags`) are
  candidates, never cleaned unasked.
- **Scratch files.** Root-level `*.scratch.md`, `ORCHESTRATION*.md`, `HANDOFF*.md`, decision and
  checkpoint notes: cleaned when this session wrote them or the run they belong to is verified
  finished, otherwise candidates. An `orchestration-state` branch goes only when the user confirms
  its run is finished.
- **Exclude entries.** Plain-path lines in `info/exclude` whose path no longer exists are cleaned.
  Globs and directories stay.
- **Temp output.** Run output in the session scratchpad is cleaned without asking; it is yours.

Stage by explicit path if anything here needs a commit; `git add -A` sweeps the untracked scratch
files that live in the worktree root.

## 3. Memory

The memory directory holds knowledge that is not in the repo, never a status report or a list of
owed work. For each finding:

- `index_without_file` and `file_without_index`: fix the index so every memory is reachable and no
  pointer dangles.
- `status_language`: a memory that says something is "still owed", "pending" or "in flight" was a
  status report when written. Verify the fact (is the PR merged, is the branch gone) and rewrite the
  memory to the durable fact, or delete it when nothing durable remains. Ask when you cannot verify.
- `dangling_paths`: a memory naming a local file, script or flag that no longer exists is wrong. Fix
  the reference or delete the memory. Paths on other machines are not checked.

Rewrite or delete only when this session changed the fact or verified it changed. Memories are the
user's notes to future sessions, so a memory you merely disagree with is a candidate, not a fix.

## 4. ADRs

Only when the repo keeps decision records under `docs/adr` with an index in its `README.md`; the
section is empty otherwise. The index is the source of truth for what is in force, and the survey
compares it with the files:

- `file_without_index_row` and `index_row_without_file`: fix the index in the same change.
- `status_mismatch`: the table and the file's `- Status:` line disagree; the file wins for a
  superseded decision, the index wins for a number that was never taken.
- `superseded_without_banner`: a superseded ADR needs a banner naming its replacement so a reader
  landing on the file does not follow it.
- `implementation_mismatch`: the table's Implementation column and the file's `- Implementation:`
  line differ. Shipped work reads `Done YYYY-MM-DD`; an in-flight branch name in that line after the
  branch merged is stale and gets replaced, never appended to.

Context, Decision and Consequences of an accepted ADR are frozen; only Status, the Supersedes links
and the Implementation status section are editable. Plan, handoff, backlog and orchestration files
tracked in the repo (`tracked_plan_files`) are candidates for removal: undone work is scheduled or
dropped, never filed.

## 5. Comments and text on this branch

The survey scans the lines this branch adds over the base ref:

- `dashes`: em or en dashes in authored text, reported only when the repo's own instructions forbid
  them (the survey looks for the rule in `AGENTS.md` or `CLAUDE.md` at the root and names the file
  in `dash_rule_source`; with no rule the list stays empty and `dashes_skipped` says why). The scan
  validates its pattern against a planted positive control first, because `grep -P` on some systems
  reports zero matches without failing.
- `comment_smells`: comments that narrate the task ("fix for", "we found", a ticket or PR number),
  `long_comment_blocks` of plain `//` or `#` lines over three long, and `commented_out_code`. Delete
  the comment when the code says it already; keep one terse line when the why is a hidden constraint.
- `ui_text_references`: an internal document cited in a string an end user can read (an ADR, issue
  or PR number inside a quoted string or a resx value). Users cannot open those, so state the rule
  or its consequence in their terms and keep the reference in a code comment.

Fix these in the branch's own commits; they are review findings, not cleanup candidates.

## 6. Threads

Resolve the pull-request review threads and artifact comment threads this session addressed
(`gh api` for review threads, the Artifact tool for artifact comments). Leave open the ones still in
conversation or that the session did not act on, and say which.

## 7. Report

End with a report that stands on its own:

```markdown
## Cleaned
- <item>: <what was done>

## Left on purpose
- <item>: <why it stays>

## Needs your call
- <item>: <what is unclear, and the command that would remove it>
```

Put the "Needs your call" items to the user with `AskUserQuestion` rather than only listing them. An
empty section is written as "nothing", not omitted; the reader must be able to tell "nothing to do"
from "not checked".
