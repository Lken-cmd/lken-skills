# AGENTS.md — <project>

_What this is, what it runs on, and the constraint that binds. One paragraph._

## Architecture — deep modules

- Do not introduce an interface with only one implementation. One adapter is a
  hypothetical seam; two is a real one. Keep test-only seams internal.
- Do not add a wrapper, port, or forwarding layer that only renames or relays
  another interface. Deletion test: if deleting it spreads its complexity across
  callers, keep it; if the complexity disappears, it is a pass-through.
- Construct nothing a caller could pass in.
- Test through a module's interface, not past it. When deepening replaces a
  shallow module, replace its tests rather than layering new ones over them.
- Do not deepen stable code the current change does not touch.
- Use module, interface, implementation, depth, deep, shallow, seam, adapter,
  leverage and locality exactly. Do not substitute component, service, API or
  boundary. A rendering unit is a component, not automatically a module.

## Verification

- Never report a check you did not run.
- State every check you could not run, and why, in the final response.
- Do not state that a change works without having run it. Say what you ran.
- Do not weaken a test, lint rule, type check, or this file to make failing work
  pass.

| Layer | Command |
|---|---|
|  |  |

_One row per way this project can fail. Name what only the hardware, the device
or the network can verify._

## Commit messages

Conventional Commits, full-sentence subject.

    <type>(<scope>): <a sentence stating what is now true, lower-case, no trailing period>

- type: feat, fix, docs, refactor, test, perf, chore, ci, build, revert.
- scope: the area, not the file.
- subject: a claim, not a label.
- Group commits by intent, not by touched file.
- Never add a Co-Authored-By trailer or any AI attribution to a commit message
  or PR description.

## Repo hygiene and secrets

- Inspect the full staged diff before every commit.
- Never commit credentials, tokens, API keys, or `.env` files.
- Never commit local usernames, absolute paths, machine names, serial numbers,
  device identifiers, or private notes. Use generic examples instead.
- Never commit build output, package caches, binaries, crash dumps, debug
  symbols, captures, or logs.
- Never echo a secret's value into a log, a commit message, or tool output.
- If sensitive data reached a commit, stop. Do not push or publish until the
  history is cleaned and the exposed secret is rotated.

## Dependencies

- Query the registry for a version. Never state one from memory.
- Take the latest stable release when adding a dependency. Do not bump an
  installed one unless something forces it.

## What the session leaves behind

- Correct or delete every document the change made stale — this file, READMEs,
  comments, decision records — in the same commit as the change.
- Remove the debug logging, commented-out code, and temporary instrumentation
  you added.
- Delete the scratch and temporary files you created, inside the repo and
  outside it.
- Every branch and worktree you created is merged, deleted, or named in the
  final response as deliberately left open.
- Restore any system, device, or service state you changed in order to observe,
  before the session ends. Read the state back to confirm; the exit code of the
  command meant to clear it is not confirmation.
