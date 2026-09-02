<#
.SYNOPSIS
Usage limits and session context size as JSON.

.DESCRIPTION
limits  -> GET https://api.anthropic.com/api/oauth/usage, fetched live. The
           endpoint rate-limits aggressively, so call this at checkpoints
           rather than in a loop.
context -> the session transcript under <config>/projects, newest assistant
           message's usage block: input + cache_creation + cache_read.
           Session id from $env:CLAUDE_CODE_SESSION_ID.

The token count is reported as-is. A percentage is emitted only when the caller
passes -ContextWindow, so no window size is ever assumed here.

The count belongs to the session, not to an individual subagent: subagents share
the session's environment, so a spawned script cannot tell which agent invoked
it. The field is named session_context_tokens to keep that unambiguous.

Read-only. Writes nothing. Never emits the access token.

.PARAMETER ContextWindow
The caller's context window in tokens; enables session_context_percent.

.PARAMETER SessionId
Inspect a different session instead of the current one.

.EXAMPLE
./Get-ClaudeUsage.ps1 -ContextWindow 200000
#>
[CmdletBinding()]
param(
    [int]$ContextWindow,
    [string]$SessionId
)

$ErrorActionPreference = 'Stop'
# Resolved from the shell's home, so no drive letter or fixed root is assumed.
$ClaudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR }
              else { Join-Path (Resolve-Path '~').Path '.claude' }

$out = [ordered]@{
    limits                  = @()
    credits                 = $null
    session_context_tokens  = $null
    session_context_percent = $null
    session_id              = $null
    limits_error            = $null
    context_error           = $null
}

function Format-Span([TimeSpan]$span) {
    if ($span.TotalMinutes -lt 1) { return 'now' }
    $parts = @()
    if ($span.Days -gt 0) { $parts += "$($span.Days)d" }
    if ($span.Hours -gt 0) { $parts += "$($span.Hours)h" }
    $parts += "$($span.Minutes)m"
    return $parts -join ' '
}

# ---------------------------------------------------------------------- limits

$credPath = Join-Path $ClaudeHome '.credentials.json'
$oauth = if (Test-Path $credPath) { (Get-Content $credPath -Raw | ConvertFrom-Json).claudeAiOauth } else { $null }
if (-not $oauth) {
    $out.limits_error = 'no subscription credentials (API-key or third-party-provider auth has no subscription limits)'
}
else {
    $expiresAt = [DateTimeOffset]::FromUnixTimeMilliseconds($oauth.expiresAt).LocalDateTime
    if ((Get-Date) -ge $expiresAt) {
        $out.limits_error = "OAuth token expired at $expiresAt - run any interactive claude command to refresh"
    }
    else {
        try {
            $r = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Method Get -Headers @{
                'Authorization'  = "Bearer $($oauth.accessToken)"
                'anthropic-beta' = 'oauth-2025-04-20'
            }
            foreach ($lim in @($r.limits)) {
                if (-not $lim) { continue }
                $b = [ordered]@{ kind = $lim.kind; percent = [double]$lim.percent }
                if ($lim.scope.model.display_name) { $b.model = $lim.scope.model.display_name }
                if ($lim.resets_at) {
                    $t = ([datetime]$lim.resets_at).ToLocalTime()
                    $b.resets_at = $t.ToString('s')
                    $b.resets_in = Format-Span ($t - (Get-Date))
                } else {
                    $b.resets_at = $null
                    $b.resets_in = $null
                }
                $out.limits += $b
            }
            if ($r.spend -and $r.spend.enabled) {
                $div = [Math]::Pow(10, $r.spend.used.exponent)
                $out.credits = [ordered]@{
                    used     = [double]$r.spend.used.amount_minor / $div
                    limit    = [double]$r.spend.limit.amount_minor / $div
                    currency = $r.spend.used.currency
                }
            }
        }
        catch {
            $out.limits_error = if ([int]$_.Exception.Response.StatusCode -eq 429) {
                'rate limited (429) - treat as unchanged since the last reading and retry later'
            } else { $_.Exception.Message }
        }
    }
}

# --------------------------------------------------------------------- context

$id = if ($SessionId) { $SessionId } else { $env:CLAUDE_CODE_SESSION_ID }
$out.session_id = $id

function Find-LatestUsage([string[]]$lines) {
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ([string]::IsNullOrWhiteSpace($lines[$i])) { continue }
        try { $o = $lines[$i] | ConvertFrom-Json } catch { continue }
        if ($o.type -eq 'assistant' -and $o.message.usage) {
            $u = $o.message.usage
            return [int]$u.input_tokens + [int]$u.cache_creation_input_tokens + [int]$u.cache_read_input_tokens
        }
    }
    return $null
}

if (-not $id) {
    $out.context_error = 'no session id (CLAUDE_CODE_SESSION_ID unset and no -SessionId given)'
}
else {
    $transcript = Get-ChildItem (Join-Path $ClaudeHome 'projects') -Recurse -Filter "$id.jsonl" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $transcript) {
        $out.context_error = "no transcript found for session $id"
    }
    else {
        # Newest assistant usage block is the live occupancy: absolute, not
        # cumulative, so it falls after a compaction. The tail is enough in
        # practice; a long transcript is only read in full when it is not.
        $tokens = Find-LatestUsage (Get-Content $transcript.FullName -Tail 400)
        if ($null -eq $tokens) { $tokens = Find-LatestUsage (Get-Content $transcript.FullName) }
        if ($null -eq $tokens) {
            $out.context_error = "no assistant message with usage yet in session $id"
        }
        else {
            $out.session_context_tokens = $tokens
            if ($ContextWindow -gt 0) { $out.session_context_percent = [Math]::Round(100.0 * $tokens / $ContextWindow, 1) }
        }
    }
}

$out | ConvertTo-Json -Depth 6
