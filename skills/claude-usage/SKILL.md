---
name: claude-usage
description: Report Claude subscription usage limits (5-hour session, weekly, extra-usage credits) and the session's context token count. Use when the user asks how much usage, quota or context is left, how close to a limit we are, or whether there is room for expensive work, and at the checkpoints of a long orchestrated run where the next phase must fit in what remains.
allowed-tools: PowerShell
---

# Usage & context

Run `Get-ClaudeUsage.ps1` from this skill's folder, the base directory named when the skill loaded.
Pass the context window your model runs with so the script can turn the raw count into a percentage:

```powershell
& "<skill folder>\Get-ClaudeUsage.ps1" -ContextWindow 200000
```

| parameter | effect |
|---|---|
| `-ContextWindow <tokens>` | also emits `session_context_percent`. Leave it out when unsure of the window and report tokens instead; the script never guesses a window size. |
| `-SessionId <uuid>` | inspect a different session instead of the current one |

## Output

| field | meaning |
|---|---|
| `limits[]` | one per bucket: `kind` (`session`, `weekly_all`, `weekly_scoped` with its `model`), `percent` used, `resets_at` (local time), `resets_in` (e.g. `2d 4h 12m`) |
| `credits` | extra-usage spend: `used`, `limit`, `currency`; null when extra usage is disabled |
| `session_context_tokens` | tokens in the session's context right now |
| `session_context_percent` | the count over `-ContextWindow`; null when the window was not given |
| `session_id` | which session the token count came from |
| `limits_error`, `context_error` | null, or why that half is missing |

## Reading it

- Headroom is `100 - percent` of the tightest bucket; the session bucket usually binds first and
  the weekly one decides whether tomorrow's work fits.
- The count is the main session's. A subagent's own context is not available here: use this for
  the limits and take your own context from your system prompt.
- The count is absolute, not cumulative. It drops after a compaction and excludes the turn in
  progress, so a reading taken right after a large tool result is already low.
- The limits endpoint rate-limits aggressively. Call this at checkpoints, not in a loop, and treat
  a 429 as "unchanged since last reading", not as headroom.
- The two halves fail independently. If an `_error` is set, report that half as unknown rather
  than assuming headroom.
- Report one line per bucket with percent and reset time, then the context line. Numbers are the
  answer here; skip the narration.
