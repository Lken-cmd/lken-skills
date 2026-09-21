# Resuming a run in flight

Reached from `SKILL.md` § 1 when `ORCHESTRATION.md` or the `orchestration-state` branch already
exists. A run resumed from either one skips the rest of intake.

## Restore the state file

If `ORCHESTRATION.md` is in the repo root, read it, restate the **Next action** and the run contract
back to the user, and pick up there. Only re-ask the contract if the user says the terms have
changed.

If the file is gone but the state branch exists (`git rev-parse -q --verify orchestration-state`),
the run is still in flight: restore the file with
`git show orchestration-state:ORCHESTRATION.md > ORCHESTRATION.md`, re-add the exclude entry (it is
local to the clone and does not travel with the branch), and resume. When both exist and differ, the
working file is the newer one; its last edit simply was not committed yet.

## Trust git over the file

**A resumed run may have died mid-phase.** If any phase's status is `dispatched`, `built`, or
`fixing`, the previous session was interrupted partway: check that branch with
`git log <base>..<branch> --oneline` and `git status --short` to see what actually landed. Three
cases, and they need different handling:

- **Commits present, status `dispatched`** — the subagent worked and the session died before
  recording it. Go straight to the review step rather than dispatching again.
- **Nothing committed, status `dispatched`** — the subagent died early or never started.
  Re-dispatch, after confirming the working tree is clean.
- **Uncommitted changes on the branch** — partial work from a subagent that never finished. Show the
  user `git status --short` and ask whether to commit it as the phase's starting point or discard
  it. This one is the user's call; it's their work at stake.

Re-dispatching over a branch that already has commits is the failure this check exists to prevent —
it produces duplicated or conflicting work that the review then has to untangle.
