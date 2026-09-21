---
name: orchestrate
description: Drive an already-designed feature to completion one delegated phase at a time, across as many sessions as it takes.
argument-hint: "[path, ticket, or plan for the settled design] [--review-at-end]"
disable-model-invocation: true
---

The design is done. This skill executes it.

You are the **orchestrator**: you hold the plan, delegate each phase to a fresh subagent, judge the result, and keep the run alive across session boundaries. Your context window is the scarce resource in this run — every token you spend reading implementation detail is a phase you can't reach. So you delegate the reading and the writing, and you keep only the map.

## Execute, don't design

The design arrived settled — usually from a `/mattpocock-skills:grill-with-docs` session, sometimes as a spec on the issue tracker or a plan file. Every decision in it was already put to the user and answered. Do not re-open those decisions, and do not make new ones on their behalf.

When a genuine design question surfaces mid-run — the plan is silent on something and the answers differ materially — that is a **pause and ask**, not a judgement call. Grilling is where decisions get made; the orchestrator's job is to notice the gap, record it in the state file, and put it to the user. Mechanical choices inside a settled design (naming, file placement, which existing helper to reuse) are yours and the subagent's to make.

## 1. Intake

### Locate the plan

In order: the path or ticket the user passed as an argument; a spec on the issue tracker, when the repo's agent instructions name one; a plan or spec file under `docs/`, `specs/`, or `.scratch/`; the tail of this conversation if a grilling session just concluded here.

If nothing is found, stop and ask. Do not start a run against a design you inferred.

### Resume instead, if there's a run in flight

`ORCHESTRATION.md` in the repo root, or an `orchestration-state` branch, means this is a resumed run: follow [`RESUMING.md`](RESUMING.md) and skip the rest of intake. It covers restoring the state file and reading git for what the dead session actually landed — a resumed run may have died mid-phase, and re-dispatching over a branch that already has commits is the failure that check exists to prevent.

### Cut the plan into phases

A phase is one subagent's worth of work that ends in a committed, reviewable, coherent change. If the plan already delineates phases, use its boundaries. If it doesn't, propose a split — this is slicing an agreed design, not designing.

Each phase needs **acceptance criteria written down** before it starts. This isn't ceremony: `/mattpocock-skills:code-review`'s Spec axis diffs the work against a spec, and with no per-phase spec it reports "no spec available" and you get half a review, every phase. Two or three concrete assertions per phase is enough.

Mark each phase's **dependencies** on earlier phases. Most will be linear. Note the ones that genuinely aren't.

Put the phase table to the user and get agreement before phase 1.

### Establish the run contract

Ask these together, in one message:

1. **How many subagents may run at once?** Default **1**. This is the lever against the 5-hour limit — concurrency multiplies burn rate against a shared quota. Only raise it if the phase table has genuinely independent phases *and* the user has quota headroom; above 1, [`PARALLEL.md`](PARALLEL.md) holds the two constraints that then bind — parallel phases cannot be stacked, and their subagents need worktree isolation.
2. **Which model tier for building, and which for reviewing?** Default **Opus for both**. Offer Sonnet for the build tier as the cheaper option: implementation against a settled plan with written acceptance criteria is well-specified work, and it's where the volume is. Recommend keeping review on Opus whichever they pick — a missed finding propagates up the whole stack.
3. **Create a PR after each phase, or one at the end?**
4. **Pause after each phase so the user can look, or run to the end?**
5. **Code review after each phase, or one review at the end?** Default **per phase**: a finding in phase 1 is cheapest to fix before phases 2 to 5 build on it. Review at the end runs the review once over the whole stack, which saves the two review agents per phase and suits short stacks of small phases. Its cost is that every finding lands after all the code exists, so fixes ripple through the stack. Pair it with PRs at the end; per-phase PRs with an at-end review would need each fix rebased into the phase branch that owns the code. Everything that changes when review defers is under *Review at the end* (§ 3).

A term the user passed as an argument (`--review-at-end`) counts as answered; ask only the rest.

**Name the tier on every spawn.** An omitted `model` silently inherits yours, which defeats the term — and that holds for the build agent and for the review's two axis agents alike. A phase left on the default runs three Opus agents before any fix rounds, which is why this is a contract term and not an afterthought.

Then take a **baseline `/claude-usage`** before phase 1 and record it. The baseline is what makes the per-phase burn rate measurable, and the burn rate is what lets you predict that phase 5 won't fit *before* you start it rather than after.

## 2. The state file

`ORCHESTRATION.md` in the repo root, excluded via the repo's **`info/exclude`** — not `.gitignore`. Editing the tracked `.gitignore` would show up in every phase diff and `/mattpocock-skills:code-review` would rightly flag it. Append to the file `git rev-parse --git-path info/exclude` names, not to a literal `.git/info/exclude`: in a worktree `.git` is a file, and the exclude list lives in the main repository where every worktree shares it.

**Write it atomically.** Temp file then `os.replace`/`mv`, or a targeted edit. **Never a truncating open** (`open(p,"w")`, `>`, `Set-Content`) — the truncation lands even when the write then fails. Prefer targeted edits to whole-file rewrites.

**Commit every checkpoint to the state branch**, `orchestration-state` by default: a branch never merged and never checked out, holding this file alone, so it reaches no phase diff, review or PR. Branches are shared by every worktree of a repository, so two runs in one repository need distinct names; suffix the feature slug and record the name in the run contract. The recipe stages the blob in a throwaway index, so the real index, the working tree and `HEAD` stay untouched:

```bash
blob=$(git hash-object -w ORCHESTRATION.md)
export GIT_INDEX_FILE=$(git rev-parse --git-path orchestration.index)
git update-index --add --cacheinfo "100644,$blob,ORCHESTRATION.md"
tree=$(git write-tree); rm -f "$GIT_INDEX_FILE"; unset GIT_INDEX_FILE
parent=$(git rev-parse -q --verify orchestration-state || true)   # `|| true`: empty on the first run
commit=$(git commit-tree "$tree" ${parent:+-p "$parent"} -m "orchestration: <what changed>")
git update-ref refs/heads/orchestration-state "$commit"
```

Nothing goes through stdin, so the same steps translate to PowerShell or Python unchanged. `git mktree` looks like the shorter route, but it reads the entry from stdin, and a CRLF there (a PowerShell pipe, Python text mode on Windows) silently stores the path as `ORCHESTRATION.md\r`, which `git show` then cannot find. Do not pre-create the index file: git rejects an empty one, and it creates the file itself.

Recover: `git show orchestration-state:ORCHESTRATION.md`. Timeline: `git log orchestration-state`. **Run the recover command once per run**, right after the first commit, and check that it prints the file; a path error means the tree entry is broken and every later checkpoint would inherit it. Delete the branch only when the user confirms the run is finished and verified: `git branch -D orchestration-state`.

It is the run's durable artifact: if the session dies mid-phase or you hit a limit without warning, this file is the only thing that survives. So the rule is stronger than "update it each phase" — **never let a fact live only in your context.** Anything the next session would otherwise have to re-derive goes in the file *before* you do the next thing.

```markdown
# Orchestration — <feature>

## Run contract
Plan: <path / ticket URL>   Concurrency: <n>   PRs: <per-phase | at end>   Pause: <per-phase | run to end>
Models: build <tier> / review <tier>   Base branch: <main>   State branch: orchestration-state
Review: <per-phase | at end>   Context pause threshold: 55%

## Phases
| # | Phase | Depends on | Branch | Base | Status | Commit | PR |
|---|-------|-----------|--------|------|--------|--------|-----|
<!-- Status: pending | dispatched | built | reviewed | fixing | done -->

## In flight
<the phase currently dispatched, its branch, and what the subagent was told to do —
 or "nothing dispatched" when between phases. This is what tells a resumed session
 whether a branch already has work on it.>

## Acceptance criteria
### Phase 1 — <name>
- <assertion>

## Usage checkpoints
| after phase | session % | weekly % | context tokens | context % |
|---|---|---|---|---|

## Review outcomes
<per phase, or one "Final review" block when the contract reviews at the end: findings fixed;
 findings consciously skipped, with the reason. Until a deferred review has run, the block reads
 "Final review: pending" so a resumed session knows the run is not finished.>

## Deferred questions
<design gaps found mid-run and awaiting the user>

## Next action
<the single next thing a fresh agent should do>
```

Reference specs, ADRs, and commits by path or URL rather than restating them, and redact anything sensitive. Because this file already carries the whole run, a separate handoff document on top of it is usually redundant.

### When to write

You can only write while you hold the turn, and during a long subagent run you don't. So the checkpoints that matter are the moments either side of delegating — write at all six:

1. **Before phase 1** — the whole file: contract, phase table, acceptance criteria, baseline usage.
2. **Before dispatching a subagent** — branch created, status `dispatched`, and the **In flight** block filled in with what you're about to ask for. Write this *before* the spawn, not after. If the session dies during the phase, this block is the difference between a resumed session understanding the branch and one spawning a second subagent over the first one's work.
3. **The moment a subagent returns** — status `built`, commit SHA, and its reported deviations and open questions. This is the highest-value checkpoint in the loop: the code is already safe in git, but the *report* exists nowhere but your context, and it's what makes the review meaningful.
4. **When the review comes back** — findings recorded before you start fixing, status `reviewed`. Review output is expensive to regenerate; losing it means paying for the review twice.
5. **After each fix round** — what got fixed, what you skipped and why, status `fixing` until it settles.
6. **At phase end** — status `done`, PR link, usage row, and a fresh **Next action**.

Keep **Next action** current at every one of these, not just at phase end. It's the first thing a resumed session reads, and it's worthless if it describes a step you finished twenty minutes ago.

Patch the file with targeted edits — amend the row, replace the block. Don't rewrite the whole document each checkpoint: it only grows, and re-emitting it six times a phase spends the window you're protecting. **Each of these six writes ends with the `orchestration-state` commit (§ 2).**

## 3. The phase loop

For each phase, in dependency order:

Each step below ends with a state-file write — checkpoints 2 to 6 of *When to write*. Treat the write as part of the step, not as bookkeeping to batch up later.

**Branch.** Stacked onto `main`: phase 1 branches off `main`, phase N branches off phase N-1's branch. Record the base — you need it twice, for the review fixed point and for the PR target.

**Delegate.** Fill in **In flight** and set the status to `dispatched` *first* — then spawn. Spawn a **fresh `general-purpose` subagent** per phase, at the contract's **build tier**. `general-purpose` is the right type because it has full tool access and can actually write and run things; `Explore` and `Plan` are read-only and can't implement.

Never reuse a subagent across phases: a reused agent carries the previous phase's context as noise, and its own window is a resource too. Give it:

- The phase brief and its acceptance criteria, verbatim.
- The plan's path, plus any ADRs and the domain glossary covering the area — let it read what it needs rather than pasting the design in.
- The branch it is on, and: **commit your work on this branch before returning.** Uncommitted work is invisible to the review step — see below.
- Scope fence: touch only what this phase covers; leave later phases alone.
- Escalation rule: if a design decision is needed that the plan doesn't settle, stop and report it — do not decide it.
- Return contract: a short report — files touched, commit SHA, deviations from the brief, open questions. **Not the diff.**

When it returns, record the SHA, deviations, and open questions before doing anything else — including before starting the review. That report is unrecoverable if the session ends here.

**Review**, when the contract reviews per phase — for the other branch see *Review at the end* below. Run `/mattpocock-skills:code-review` with the phase's **base branch as the fixed point** and the phase's acceptance criteria as the spec. Set the **review tier** on both of its axis sub-agents. This is exactly the right fixed point for a stack: `git diff <base>...HEAD` isolates this phase's changes from everything beneath it.

The subagent must have committed for this to work at all — `/mattpocock-skills:code-review` compares against `HEAD`, so uncommitted work yields an empty diff and the review fails at its own first step. If the subagent returned without committing, commit its work yourself before reviewing.

**Triage.** Record the findings before you start fixing any of them. Documented-standard violations get fixed. Baseline smells are judgement calls — decide each, and record the ones you skip *with the reason* in the state file; an unexplained skip is indistinguishable from an oversight to the next session. Fixes land as follow-up commits on the phase branch. If the fix set is large, delegate it to a fresh subagent at the **build tier** rather than doing it yourself — that's an implementation task, and implementation belongs out of your context.

Re-review only if the fixes were substantial enough to plausibly introduce new findings. After **two** fix rounds that don't converge, stop and escalate: something in the phase brief is wrong, and a third round won't find it.

**PR**, if the contract says per-phase: `gh pr create --base <the phase's base branch>`. The PR body states its position in the stack and links the phase's acceptance criteria. When a PR low in the stack merges, retarget the one directly above it.

**Checkpoint.** Run `/claude-usage` and append a row. Once per phase boundary; the limits endpoint rate-limits aggressively.

**Then evaluate the gates below**, and pause or continue per the contract.

### Review at the end

When the contract defers review, three things change. Each phase skips the Review and Triage steps: it is `done` once its commit is recorded, and goes on to PR and Checkpoint. Checkpoints 4 and 5 of *When to write* happen once rather than per phase. And the last phase does not end the run.

Run `/mattpocock-skills:code-review` once with the run's **base branch as the fixed point** and every phase's acceptance criteria, concatenated, as the spec, then triage exactly as above. Fixes land as follow-up commits on the top branch of the stack, delegated at the build tier when the set is large. Record the findings under **Final review** before fixing any of them. The two-round convergence limit still applies: a stack that does not converge has a wrong phase brief somewhere, and the phase table says which phase owns the code the findings cluster in.

The review and its fix rounds cost about one phase. Check the gates before starting it and hand off rather than begin a review that cannot finish; a resumed session picks it up from **Next action** like any phase.

## 4. Gates

Check both after every phase, before starting the next, and before a deferred final review.

**Context.** Pass your context window to `/claude-usage` (`-ContextWindow`) and read `session_context_percent`; without the window, divide `session_context_tokens` by it yourself. At **55%** or above, stop taking new phases: finish what's in flight, bring the state file current, and hand off. The threshold sits well below the limit because a phase you start at 60% may not have room to finish — and a phase abandoned mid-flight costs more than one deferred cleanly.

**Quota.** Compare the burn of the last phase against what's left in the session and weekly buckets. Never start a phase whose projected cost exceeds the remaining session quota — a phase interrupted by a hard limit leaves a half-built branch and an unreviewed diff. If a `limits_error` or `context_error` is set, treat that half as unknown and be conservative rather than assuming headroom.

Either gate tripping means the same thing: hand off.

## 5. Handing off

If the checkpoint discipline held, `ORCHESTRATION.md` is already current and handing off is mostly confirmation: verify the phase table, usage rows, and review outcomes match reality, and sharpen **Next action** until it's specific enough to act on without re-deriving anything. Add a suggested-skills line if the next session will need particular ones.

A planned handoff is the easy case — the file was written for the unplanned one.

Leave it off the working branch — it stays in the repo root, and its history is on `orchestration-state` (§ 2). **Commit the final checkpoint there before you stop.**

**Never commit it to a phase branch.** To move the state to another clone, push `orchestration-state`. Tell the user the branch exists and that only they end it.

End with a **resume prompt**: a fenced block the user pastes into a fresh session **unedited**, and
nothing after it. Anything that needs an answer from the user goes in your message *above* the
block, never inside it: a question in the paste is a question they would be pasting to the next
agent instead of answering.

```text
/orchestrate <plan path or ticket>

Resuming the orchestrated run in <repo path>. ORCHESTRATION.md in the repo root holds the state;
if it is gone, restore it with `git show orchestration-state:ORCHESTRATION.md > ORCHESTRATION.md`.

Next action: <the Next action line, verbatim>
Read the file's Deferred questions first and put any still open to me before starting a phase.
```

Above the block, say where the run stands in a line or two and spell out each deferred question, so
the user can answer now without opening the file. The block itself carries only what a fresh session
cannot recover for itself: which repo the run lives in, that a run is in flight, and that the file
may hold questions. Everything else it reads from the file, which is why the block points at it
rather than summarising it. Print the block whenever you stop on a gate (§ 4) or the user ends the
session, not at a per-phase pause, which keeps the same session alive.

## Context hygiene

The failure mode of this skill is an orchestrator that gradually turns into an implementer and runs out of window at phase 3. Four habits hold the line:

- What's in a file is a question for a subagent; ask it and keep the answer.
- `--stat` gives you the shape of a diff. The review reports are your view of its content.
- Gist what a subagent or a review returns into the state file: outcomes and decisions, not transcripts.
- Every edit goes to a subagent, quick fixes included — or you make it knowing you spent window on it.
