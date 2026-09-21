---
name: claude-usage
description: Report Claude subscription usage limits (5-hour session, weekly, extra-usage credits) and the session's context token count. Use when the user asks how much headroom is left against a limit, and at the checkpoints of a long orchestrated run where the next phase must fit in what remains.
allowed-tools: PowerShell
---

# Usage & context

Run `Get-ClaudeUsage.ps1` from this skill's folder, the base directory named when the skill loaded.
Pass the context window **your own model runs with**. The script never guesses one, and a wrong
value rescales every percentage without any sign of it: 200000 passed for a session actually running
at 1M reported 43% where the truth was 9%. Your system prompt names the model and a `[1m]` suffix
means 1000000 — but the surest source is the client's own context display, which states the window
outright. If you cannot establish it, omit the parameter and report tokens; the script echoes back
`context_window` and `context_window_source` so a wrong denominator stays visible.

```powershell
& "<skill folder>\Get-ClaudeUsage.ps1" -ContextWindow 1000000
```

| parameter | effect |
|---|---|
| `-ContextWindow <tokens>` | also emits `session_context_percent`. Leave it out when unsure of the window and report tokens instead; the script never guesses a window size, and the transcript does not record one. A count above the window given is impossible, so it is reported as a wrong window rather than divided out. |
| `-SessionId <uuid>` | inspect a different session instead of the current one |
| `-RequireAccountMatch` | fetch no limits at all when the only token belongs to another account. Use it when a wrong number is worse than none — budgeting a long run, say |
| `-UseStoredToken` | under host-managed auth, read the stored CLI login's subscription anyway, labelled with the account it belongs to. For inspecting *that* account on purpose — it does not recover this session's limits |

## Whose limits, per surface

No setup on any surface. All of them read the same stored login; what differs is how
well the reading can be tied to the session, which is what `account_mismatch` reports.

| surface | limits | attribution |
|---|---|---|
| terminal CLI | yes | verified — `auth_mode: local`, the credentials file *is* this session's login |
| Claude desktop app | yes | verified — its `cwd` names the account, matched against the stored login |
| VS Code extension, SDK harness | yes | **`unverified`** — host-managed, names its account nowhere on disk |

Only the terminal CLI writes `.credentials.json` — `/login` and its token refresh. Both GUI
surfaces authenticate over IPC and keep their own credential elsewhere, which is why neither
can be read directly and why the file they fall back on is the *CLI's* login, a separate
lineage from whatever they signed into. An `unverified` reading is therefore right on a
single-account machine and wrong without warning on a machine with two, so always report the
account next to the numbers. `-RequireAccountMatch`
refuses instead of reporting, for when a wrong number is worse than none — an orchestrated
run budgeting a long phase, say. Setting `CLAUDE_USAGE_OAUTH_TOKEN` from `claude setup-token`
removes the doubt permanently, but nothing requires it. Never run that command for the user
and never handle the token value; the script puts the platform-correct form in
`account_mismatch`, so relay it.

## Output

| field | meaning |
|---|---|
| `limits[]` | one per bucket: `kind` (`session`, `weekly_all`, `weekly_scoped` with its `model`), `percent` used, `resets_at` (local time), `resets_in` (e.g. `2d 4h 12m`) |
| `credits` | extra-usage spend: `used`, `limit`, `currency`, `unlimited`; null when extra usage is disabled. `limit` is null with `unlimited: true` when no monthly cap is set — report the spend alone, never as a fraction of zero |
| `account` | **whose limits these are**: `email`, `account_uuid`, `organization_uuid` |
| `session_account` | who the session runs as, from its transcript; null when unstamped |
| `account_mismatch` | null when the two match. Starts `pinned:` when a minted token was used — a note on which subscription is measured, not a warning. Otherwise why the check failed: a wrong account, or that it could not be made |
| `auth_source` | which token the limits half used: `env:CLAUDE_USAGE_OAUTH_TOKEN` (the pinned one, the intended path), `env:CLAUDE_CODE_OAUTH_TOKEN`, a `file:` path, the macOS keychain, or an `apiKeyHelper`. Null when no limits were fetched |
| `auth_mode` | `local` when the token came from disk or the environment; `host-managed` when the desktop app or SDK holds it in memory and nothing readable belongs to this session |
| `credentials_file` | the stored login's path, or null when this machine has none. Null is the one case that is not a malfunction: both GUI surfaces keep their login inside their own process, so a machine driven only through them never writes the file. `limits_error` then opens `NO STORED LOGIN ON THIS MACHINE` — relay that as the reason, and say context is unaffected |
| `session_context_tokens` | tokens in the session's context: prompt + the last reply |
| `session_context_percent` | the count over `context_window`; null when the window was not given, or when the count exceeded it |
| `context_window`, `context_window_source` | the denominator actually used and where it came from (`parameter`, or `unknown` when none was given) — check these before trusting a percentage |
| `context_breakdown` | the same count split into `prompt` and `output` |
| `session_model`, `session_id`, `config_dir` | which model, session and config directory the count came from |
| `limits_error`, `context_error` | null, or why that half is missing |

## Reading it

- Headroom is `100 - percent` of the tightest bucket; the session bucket usually binds first and
  the weekly one decides whether tomorrow's work fits.
- The count is the main session's. A subagent's own context is not available here: use this for
  the limits and take your own context from your system prompt.
- The count is absolute, not cumulative. It drops after a compaction, and it trails by one turn:
  it is what the last request carried, so tool results returned since are not in it yet. Read it
  as a floor, and treat a reading taken right after a large tool result as already stale.
- The limits endpoint rate-limits aggressively. Call this at checkpoints, not in a loop, and treat
  a 429 as "unchanged since last reading", not as headroom.
- The two halves fail independently. If an `_error` is set, report that half as unknown rather
  than assuming headroom.
- **Always report `account` alongside the percentages.** The usage endpoint names no account, so a
  token for the wrong login returns a perfectly plausible number for a subscription this session
  never spends against — a wrong reading looks exactly like a right one. Naming the account is what
  makes it catchable.
- **The app's signed-in account and the CLI's on-disk login are independent.** Signing the desktop
  app into one account does not touch `~/.claude/.credentials.json`, which keeps whatever the last
  CLI `/login` left there — possibly a different account, on a different plan, with unrelated
  limits. Measured on this machine 2026-09-03: the app was signed in as a Team account while the
  credentials file still held a personal Max login, unmodified from hours earlier, and the two
  subscriptions' weekly figures were 56% and 4%. Do not treat "logged in" in one surface as
  evidence about the other.
- **`auth_mode: host-managed` is not by itself a failure.** It means the session's own token lives
  in its host's memory and arrives over IPC — in no file, no environment variable, no local cache,
  so it cannot be borrowed. What decides whether limits are still readable is the *account*: a
  desktop-app session names its own in its cwd
  (`...\Claude\scratch-workspaces\<accountUuid>\<organizationUuid>\...`), so the stored login can be
  matched to it and used when they agree. Check `session_account` against `account`; a null
  `account_mismatch` with both populated means the reading was verified, not merely plausible.
- **A host-managed session with no account signal reports `unverified`, it does not refuse.** The
  VS Code extension and SDK harnesses leave nothing to match — not in the transcript, not in
  `~/.claude/ide/*.lock`, not in `~/.claude/sessions/*.json`. Refusing outright was tried and was
  an overcorrection: it silently zeroed out the extension the moment Claude Code moved it to
  host-managed auth, which is how this skill came to report nothing on its most-used surface.
  Unverifiable is not the same as wrong. Report the numbers *with the account beside them* so a
  wrong one is visible, and use `-RequireAccountMatch` when a wrong number would be worse than
  none.
- **Do not suggest `CLAUDE_CODE_OAUTH_TOKEN` as a machine-wide variable.** It is read here, but it
  is also an authentication source for Claude Code itself, so setting it persistently moves *every*
  session onto that token's account. `CLAUDE_USAGE_OAUTH_TOKEN` is read by this script and nothing
  else, which is the whole reason it exists.
- **The statusLine route does not exist; do not re-investigate it.** Its payload does carry
  `rate_limits` and the true context window, but a status line is a terminal footer. Measured
  2026-09-21 with `refreshInterval: 2`: zero invocations in the VS Code extension across two
  restarts, zero in the Claude app. The same script registered as a `PostToolUse` hook, same command
  line, fired immediately — so the command spawner works and the absence is the feature's, not the
  setup's. Hook input carries no limits data either.
- `account_mismatch` is not always decidable. Only bridge sessions stamp an owner on their
  transcript, so for most sessions it says *unverifiable* and names the account anyway. Treat that
  as "check this is the right login", not as a pass. A non-null mismatch that names two different
  accounts means the percentages are the wrong subscription's — say so rather than reporting them.
- `limits_error` says what to do in each case, including which token it declined to use and why, and
  carries the platform-correct setup command. Quote it rather than paraphrasing: a shell `export`
  does not reach a GUI app's environment, so the usual advice is wrong on Windows and on macOS.
  An `ANTHROPIC_API_KEY` cannot stand in — the endpoint is subscription-scoped and a key has no
  subscription. `ANTHROPIC_BASE_URL` indicates a third-party gateway only when it points somewhere
  other than `api.anthropic.com`; the desktop app sets it to the real API for its own sessions, so
  its mere presence proves nothing. The context half needs no token and works regardless.
- Report one line per bucket with percent and reset time, then the context line. Numbers are the
  answer here; skip the narration.
