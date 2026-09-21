# Running phases in parallel

Reached from `SKILL.md` § 3 when the run contract's concurrency is above 1 *and* the phases are
genuinely independent. Two constraints are not negotiable.

**A stack is linear, so parallel phases cannot be stacked.** Independent phases branch off the
*same* base and each PR into that base — a diamond, not a stack. The next stacked phase bases off
whichever of them lands last. If the user wants both a strict stack and parallelism, the stack wins;
say so and run those phases sequentially.

**Parallel subagents need `isolation: "worktree"`.** Two agents editing one working tree will
clobber each other's edits and produce a diff neither of them intended. Worktree isolation costs
setup time and disk; running parallel phases without it costs the phases.

Review each parallel phase against its own base independently, as soon as it is ready — a phase that
has returned gets reviewed while its sibling is still building.
