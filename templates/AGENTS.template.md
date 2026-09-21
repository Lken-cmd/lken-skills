# AGENTS.md: <project>

> Italic lines and `<angle brackets>` are fill-in instructions for this template. Delete each once
> it is filled, including this one.

_What this is, what it runs on, and the constraint that binds. One paragraph._

## Where the knowledge lives

- Naming a type, writing text a user reads, or meeting an unfamiliar domain word:
  [CONTEXT.md](CONTEXT.md), the domain glossary. Use its headword everywhere you write, including
  where an entry lists `_Avoid_` words.
- Changing an existing seam, or meeting a decision that looks already made: [docs/adr/](docs/adr/),
  read first. An ADR's `Status` says whether it is in force; only an accepted one binds, and a
  superseded one names its replacement. An accepted ADR's Context, Decision and Consequences are
  frozen: you add a superseding ADR, you never rewrite them.

_One line per document worth reaching for. Lead with the branches that should trigger it, not with
the document's name: the wording decides whether it gets read._

Knowledge that outlives a change goes into an ADR, the glossary, or a README beside the code.
Undone work is scheduled in the tracker or dropped, never filed as a document in the repo.

## Rules that apply everywhere

- **A change lands complete.** Everything the change drags along goes in the same commit as the
  source edit: regenerated output, and every document it made stale (this file, READMEs, comments,
  decision records). Generated output changes at its source: edit the source, regenerate, commit
  both.
- **Frozen** means published: you add a replacement, you never rewrite it. A released interface is
  frozen, and so is anything else this project has already put in someone else's hands.

## Architecture: deep modules

**The rule this repo bends least.** Every feature is a deep module: substantial behaviour behind a
small interface at a clean seam. The interface is everything a caller must know to use the module
correctly, invariants, ordering, error modes and required configuration included, not just the type
signature. Judge depth by the leverage that interface gives callers, never by line count. Widening
an interface to save work behind it is the wrong change, whatever the deadline.

The rules below stand on their own. If your agent has the `mattpocock-skills:codebase-design`
skill, load it before designing a seam as well: it carries the dependency categories, the
worked examples and the reasoning behind the rules below.

- Introduce an interface only where something actually varies across the seam. One adapter is a
  hypothetical seam; two is a real one, and for a dependency you do not control the test adapter is
  the second. Keep test-only seams internal.
- Every layer earns its place by absorbing complexity. Deletion test: if deleting it spreads its
  complexity across callers, keep it; if the complexity disappears, it was renaming or relaying
  another interface and it goes.
- Inject what varies per caller; keep the rest behind the interface.
- Return a result rather than mutating what you were handed.
- Test through a module's interface. When deepening replaces a shallow module, replace its tests
  rather than layering new ones over them.
- Deepen only the code the current change touches; stable code stays as it is.
- When the topic is design, say module, interface, implementation, depth, seam, port, adapter,
  leverage and locality, and mean them exactly. Where the project's own domain owns one of those
  words, or owns a word like component, service or API, the domain sense wins in that context.

What the skill cannot know:

- _<any word above that also carries a domain sense in this project, and which sense wins where>_

## Verification

- Report only checks you actually ran, and name them and what they cover.
- State every check you could not run, and why, in the final response.
- Tests, lint rules, type checks and this file keep their current strength; failing work is what
  gets changed.

| Layer | Command |
|---|---|
| _<layer>_ | _<command>_ |

_One row per way this project can fail. Name the checks the environment cannot tell you about,
and what only a real device, real hardware or the network can verify._

## Testing

- **A new test earns its place by failing first.** Break the code it covers, watch it go red, put
  the code back. A test that stays green against the unfixed code proves nothing and costs suite
  time forever. This binds the fixture too: assert that the fixture itself is doing its job,
  because one that quietly stops exercising the path takes the assertions with it.
- **A flake belongs to the session that sees it.** A test that passes alone and fails in the full
  run is a defect in the test, so fix it in the run where it surfaced. What you could not reach
  is raised as work, after the fix.

## Comments and user-facing text

- Comment only the non-obvious why: a hidden constraint, a subtle invariant, a workaround for a
  specific bug, behaviour that would surprise a reader.
- One terse line is the norm. Two or three are acceptable when the hidden why needs the room; more
  is narration.
- A comment states a standing fact about the code. A measurement, a benchmark number or a ticket
  reference belongs where the reasoning lives: the ADR, or the tracker.
- One comment form per member: an inline comment or a doc comment, not both.
- Text a user reads states the rule or its consequence in their own terms. The developer-facing
  reason lives in a doc comment or beside the string, never inside it: a user cannot open an ADR,
  an issue or a pull request, so those references stay out of anything they can read.

## Commit messages

Conventional Commits, full-sentence subject.

    <type>(<scope>): <a sentence stating what is now true, lower-case, no trailing period>

- type: feat, fix, docs, refactor, test, perf, chore, ci, build, revert.
- scope: the area, not the file.
- Group commits by intent, not by touched file.
- Work on a branch and land it through a pull request. Never commit or push to the main branch.
- Tags are release versions only. Any other tag corrupts a version derived from the git history.
- Never add a Co-Authored-By trailer or any AI attribution to a commit message or PR description.

## Repo hygiene and secrets

- Inspect the full staged diff before every commit, and stage by explicit path: the worktree root
  holds untracked local files that stay local.
- A commit carries source and the artifacts the change lands with. Secrets and build output stay
  out of it, and a secret's value stays out of logs, commit messages and tool output.
- Local usernames, absolute paths, machine names, serial numbers, device identifiers and private
  notes get a generic example in their place.
- If sensitive data reached a commit, stop and say so before anything is pushed or published. The
  user rotates the secret; rewrite the history only when they ask you to.

## Dependencies

- Query the registry for a version. Never state one from memory.
- Take the latest stable release when adding a dependency. Do not bump an installed one unless
  the change you are making requires it.

## What the session leaves behind

**Everything this session created gets a verdict.** Walk the branches, worktrees and scratch files
it created, in the repo or in its scratch directory, and the memories it touched. Each gets one of
three:

- **Cleaned**, which you decide and do: an artifact this session created and no longer needs, or a
  branch already merged into the main branch.
- **Candidate**, which the user decides: unmerged work, a remote branch, anything an earlier
  session left.
- **Left on purpose**, which you decide and say: name it and the reason.

Report all three. An empty verdict is written as "nothing", so the user can tell a clean sweep from
an unchecked one.

Then, whatever the verdicts:

- Remove the debug logging, commented-out code, and temporary instrumentation you added.
- Restore any system, device, or service state you changed in order to observe. Read the state back
  to confirm; the exit code of the command meant to clear it is not confirmation.
- A memory earns its place by staying true after this session ends. Rewrite or delete one only when
  this session changed the fact it records, and keep status out of it: what is still owed belongs
  in the tracker, not in a memory.
