---
name: claude-usage
description: Report Claude subscription usage limits (5-hour session, weekly, extra-usage credits) and the session's context token count. Use when the user asks how much usage, quota or context is left, how close to a limit we are, or whether there is room for expensive work, and at the checkpoints of a long orchestrated run where the next phase must fit in what remains.
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

## Output

| field | meaning |
|---|---|
| `limits[]` | one per bucket: `kind` (`session`, `weekly_all`, `weekly_scoped` with its `model`), `percent` used, `resets_at` (local time), `resets_in` (e.g. `2d 4h 12m`) |
| `credits` | extra-usage spend: `used`, `limit`, `currency`; null when extra usage is disabled |
| `account` | **whose limits these are**: `email`, `account_uuid`, `organization_uuid` |
| `session_account` | who the session runs as, from its transcript; null when unstamped |
| `account_mismatch` | null when the two match. Otherwise why not — a wrong account, or that the check could not be made |
| `auth_source` | which token the limits half used: `env:CLAUDE_CODE_OAUTH_TOKEN`, a `file:` path, the macOS keychain, or an `apiKeyHelper`. Null when no limits were fetched |
| `auth_mode` | `local` when the token came from disk or the environment; `host-managed` when the desktop app or SDK holds it in memory and nothing readable belongs to this session |
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
- **`auth_mode: host-managed` means this session's limits are not obtainable, and that is the
  answer.** Such a session — desktop app, or any Agent SDK harness — receives its token from its
  host over IPC; it exists in no file and no environment variable. The script refuses to substitute
  the stored login's numbers and sets `limits_error` saying so. Report the limits as unknown rather
  than hunting for a number: the context half needs no token and is unaffected. Nothing readable can
  recover them — not the environment, not Credential Manager, not `claude auth status` (a freshly
  spawned CLI resolves to the on-disk login), not the app's own session state.
- **Two ways to make the limits readable again**, both requiring a deliberate act by the user:
  log the CLI in as the account you want measured (`claude auth login`) so `.credentials.json` holds
  it, then pass `-UseStoredToken` — the label will name that account, so a correct reading is
  visible as correct; or run `claude setup-token` for it and export `CLAUDE_CODE_OAUTH_TOKEN`, which
  the script prefers over everything else. The first changes which account *all* CLI sessions use,
  the second does not. Neither can be done for the user: do not run login or token commands on their
  behalf, and never handle the token value.
- `account_mismatch` is not always decidable. Only bridge sessions stamp an owner on their
  transcript, so for most sessions it says *unverifiable* and names the account anyway. Treat that
  as "check this is the right login", not as a pass. A non-null mismatch that names two different
  accounts means the percentages are the wrong subscription's — say so rather than reporting them.
- `limits_error` says what to do in each case, including which token it declined to use and why.
  An `ANTHROPIC_API_KEY` cannot stand in — the endpoint is subscription-scoped and a key has no
  subscription. `ANTHROPIC_BASE_URL` indicates a third-party gateway only when it points somewhere
  other than `api.anthropic.com`; the desktop app sets it to the real API for its own sessions, so
  its mere presence proves nothing. The context half needs no token and works regardless.
- Report one line per bucket with percent and reset time, then the context line. Numbers are the
  answer here; skip the narration.
