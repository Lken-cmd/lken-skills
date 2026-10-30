---
name: fewest-parts
description: A YAGNI deletion pass over a branch or a module, checking every part against the ask it answers and deleting it where it answers none. Use when the user asks what a branch or a module can do without, or for a YAGNI pass over one.
argument-hint: "[paths, or none for the current branch] [--parallel <n>]"
---

# Fewest parts

The best part is no part. This skill runs that rule over a whole scope at once: every part listed,
questioned, and deleted where it answers no ask.

## Parts and asks

A **part** is anything a change leaves for someone to read, build, test, configure or keep: a project, a
file, a type, a member, a parameter, a config option, a dependency, a test, a doc. Each one costs for as long
as it exists, so each answers to an **ask**:

- a requirement, issue or ticket the work implements, and the design decisions it adopts;
- a decision record in force, such as an accepted ADR;
- a rule in the project's instructions (`AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`);
- the user, in the session;
- a toolchain whose build fails without it.

**YAGNI:** a part for a case nobody has asked about waits until someone does. Where the project's instructions name
asks, test rules or commit conventions of their own, theirs win over the ones here.

## Steps

1. **Fix the scope and its asks.** A branch: the commits since its merge base with the branch its pull
   request targets (the default branch, or the parent of a stacked pull request), and only the parts they add
   or change. A module: the paths the user names, and every part they hold. Then write down every ask from
   the list above that the scope answers, each with its source, quoting the user's requests in this session.
   Done when the scope is a commit range or a list of paths and every ask is written down.

2. **Split the scope into areas** of about 20 files: one per project or package, generated code together with
   its source and generator, the docs together. Generated files are questioned at their source, and a part
   repeated across projects, such as a package every test project references, in one area only. Done when
   every file and every repeated part sits in exactly one area.

3. **Question every area with a subagent that reads its area in full and edits nothing,** at most three at
   a time, or as many as the user names with `--parallel`. With more than three areas and no number named,
   first ask the user through AskUserQuestion how many to run at once, naming the area count and
   recommending three. Give each its range or paths and the asks from step 1, with the Parts and asks
   section and the brief below verbatim. It goes through the interface part by part and the implementation
   file by file, and returns the count of parts it questioned with a row for every part whose verdict is
   not keep or whose ask is weak:
   `file:line | part | ask it answers | what breaks without it | verdict | change`. A verdict is keep, delete,
   merge into another part, reuse an existing one, or design the case away. Done when every area has
   returned.

4. **Cross-read the rows.** Settle a part that rows from two areas touch once, with both rows in view. Two
   areas can each be right alone and wrong together: one deletes test A because test B proves the same
   behaviour, the other deletes B because it can never fail, and the behaviour loses its only proof. Check
   each row's evidence against the code before acting on it. Done when no part has two rows and every row
   acted on has its evidence confirmed.

5. **Delete first.**
   - Put to the user through AskUserQuestion, before applying anything, every row whose change reaches a
     public contract, a stored or on-the-wire format, a config key users set, a decision record in force or
     another open pull request, and every row whose ask may live outside what you can read, such as a
     customer or another team. Batch them.
   - Apply the rest: the deletions, then the merges and reuses, then the cases to design away, each followed
     by the fast tests of the project it touches.
   - Red-check a test row before acting on it: copy the file the test covers, break the code in it, see which
     tests fail, and restore from the copy, since a checkout would drop this pass's uncommitted edits. Act on
     the row only when the break bears it out: where it says another test proves the same behaviour, that
     test goes red; where it says the test can never fail, the test stays green.
   - A test the row changes or merges into, if it runs threads or waits with a time limit, then proves it is
     stable: 20 green runs in a row while a full run loads the machine.
   - A part whose deletion turns a test red comes back, unless that test proves a behaviour that answers no
     ask, and then the test goes with it.

   Done when every row is applied, answered by the user, or kept with its ask named.

6. **Count what came back:** a deletion a red test brought back, a row the cross-read refuted, and a row the
   user kept. With ten rows or more, when fewer than one in ten came back, the questioning was too timid: run
   steps 3 to 5 once more, deletion first, with each questioner returning a row for every part it kept. Done
   when one row in ten has come back, the pass had fewer than ten rows, or the second pass is applied.

7. **Prove it** with the build and test commands the project's CI runs on a pull request, each from its
   working directory, and report every row's verdict with the counts of parts deleted, kept and brought back.
   Done when every command passes.

8. **Commit** on a branch, folding the changes into the commits they belong to where the branch keeps one
   commit per reason.

## The questioners' brief

Question every part in scope relentlessly, in this order:

1. **Ask:** which ask does it answer? A part kept in case it is needed has none.
2. **History,** Chesterton's fence: the commit that added it (`git log -S`), its pull request and its tests
   say what it holds up, and often name its ask; the row says what they showed.
3. **Deletion test:** delete the part in your head. If its complexity vanishes with it, it only passed
   through; if the complexity reappears in its callers, it earns its place.
4. **Reuse:** does the platform, the framework, a dependency already in use or another module's interface
   already do its job?
5. **Design:** can its case go away: a default in place of an option, an operation that cannot fail in place
   of an error path, one representation in place of two?

The parts that most often answer no ask: a parameter every caller passes the same, an option no caller sets,
an interface with one adapter, a wrapper that only forwards, a check for a state that cannot occur, a catch
that only rethrows, a dependency used for one call, a test whose behaviour another test already proves, a doc
that restates the code, a config option no user would change.
