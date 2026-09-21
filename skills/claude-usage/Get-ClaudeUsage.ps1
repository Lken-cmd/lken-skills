<#
.SYNOPSIS
Usage limits and session context size as JSON, attributed to an account.

.DESCRIPTION
limits  -> GET https://api.anthropic.com/api/oauth/usage, fetched live. The
           endpoint rate-limits aggressively, so call this at checkpoints
           rather than in a loop. It is subscription-scoped and needs an OAuth
           token, so API-key auth is reported as such rather than attempted.
context -> the session transcript under <config>/projects, newest main-chain
           assistant message's usage block: input + cache_creation + cache_read
           + output. Session id from $env:CLAUDE_CODE_SESSION_ID.

WHOSE LIMITS. The usage response names no account, so a token for the wrong
login returns a plausible number for a subscription that is not the one this
session spends against - silently. On a machine with more than one account that
is the failure that matters, so this script resolves it locally instead: the
transcript stamps ownerAccountUuid per session, .claude.json names the account
each config dir is logged in as, and the two are compared. A config dir matching
the session's owner is preferred over one that does not, the answer is labelled
with the account it belongs to, and a mismatch it cannot resolve is reported in
account_mismatch rather than passed off as the session's own usage.

Config dir resolution: $env:CLAUDE_CONFIG_DIR first, then the profile
directories, because a shell launched by the desktop app does not always resolve
'~' to the profile holding the credentials. Candidates are ordered by account
match before any is read for a token.

HOST-MANAGED AUTH, AND WHY A PINNED TOKEN IS THE ANSWER. A session the desktop
app, the VS Code extension or the Agent SDK starts does not authenticate from
disk at all: the host holds the token in memory and hands it over IPC
(CLAUDE_CODE_MESSAGING_SOCKET, CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH). No file,
no environment variable, nothing this script can read. Any .credentials.json it
does find then belongs to whoever last used the CLI, which need not be this
session's account - and because such transcripts carry no owner stamp, the
account check above has nothing to compare and waves it through. That
combination is how a reading of the wrong subscription gets reported as the
session's own, so it is refused rather than guessed at.

Chasing the host's own token is a dead end, and every route was tried: it is in
no credentials file, no environment variable and no local cache. The statusLine
payload does carry rate_limits and the true context window, but a status line is
a terminal footer and the GUI surfaces never run the command - measured
2026-09-21 with refreshInterval 2: zero invocations in the VS Code extension
across two restarts, zero in the desktop app, while the same script registered
as a PostToolUse hook fired at once. Do not re-investigate it.

What is recoverable is not the token but the ACCOUNT, and that is enough: the
stored login is safe to read as soon as it is known to be the same account the
session runs as. A desktop-app session names its own account in its cwd -
...\Claude\scratch-workspaces\<accountUuid>\<organizationUuid>\scratch-... - so
that case resolves itself with nothing to configure. A session that leaves no
such signal, an editor extension or an SDK harness, is still refused rather than
guessed at.

For that remaining case only, CLAUDE_USAGE_OAUTH_TOKEN is honoured: minted by
'claude setup-token' and set as a persistent user variable, it is inherited by
every surface's spawned processes. Deliberately NOT CLAUDE_CODE_OAUTH_TOKEN,
which is an authentication source for Claude Code itself and would move every
session onto its account; this one is read here and nowhere else. Optional - the
terminal and the desktop app need none of it.

The token count is reported as-is. A percentage is emitted only when the window
is known, and the window it used is always echoed back in context_window with
context_window_source, so a wrong percentage can be spotted instead of trusted:
passing 200000 for a session actually running at 1M is the difference between
reporting 43% and 9%. The transcript does not record the window and a model id
alone does not settle it (the same id runs at 200K and at 1M), so -ContextWindow
wins when given; failing that, the CLI's own autoCompactWindowsCache is consulted
if it happens to name this model. A count above the stated window is impossible
and is reported as such rather than divided out into a percentage.

The count belongs to the session, not to an individual subagent: subagents share
the session's environment, so a spawned script cannot tell which agent invoked
it. The field is named session_context_tokens to keep that unambiguous.

Read-only. Writes nothing. Never emits the access token.

.PARAMETER ContextWindow
The caller's context window in tokens; enables session_context_percent.

.PARAMETER SessionId
Inspect a different session instead of the current one.

.PARAMETER RequireAccountMatch
Refuse to report limits at all when the only token available belongs to a
different account than the session. Use it when a wrong number is worse than no
number - an orchestrated run budgeting against the wrong subscription, say.

.PARAMETER UseStoredToken
Under host-managed auth, fall back to a stored .credentials.json token even
though it cannot be tied to this session. The reading is labelled with the
account it actually belongs to. Use it to inspect that account deliberately, not
to get a number out of a session whose own limits are unreachable - pinning
CLAUDE_USAGE_OAUTH_TOKEN is the fix for that.

.EXAMPLE
# 1M-window session: pass the real window, or the percentage is meaningless.
./Get-ClaudeUsage.ps1 -ContextWindow 1000000

.EXAMPLE
# Deliberately read the stored CLI login's subscription from an app session.
./Get-ClaudeUsage.ps1 -UseStoredToken

.EXAMPLE
# One-time setup that makes the limits readable on every surface, GUI included.
#   claude setup-token
#   setx CLAUDE_USAGE_OAUTH_TOKEN "<token>"   # then restart the app or editor
# Nothing in Claude Code reads that variable, so it changes no session's account.
#>
[CmdletBinding()]
param(
    [int]$ContextWindow,
    [string]$SessionId,
    [switch]$RequireAccountMatch,
    [switch]$UseStoredToken
)

$ErrorActionPreference = 'Stop'

$out = [ordered]@{
    limits                  = @()
    credits                 = $null
    account                 = $null
    session_account         = $null
    account_mismatch        = $null
    auth_source             = $null
    auth_mode               = $null
    credentials_file        = $null
    session_context_tokens  = $null
    session_context_percent = $null
    context_window          = $null
    context_window_source   = $null
    context_breakdown       = $null
    session_model           = $null
    session_id              = $null
    config_dir              = $null
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

# ----------------------------------------------------------------- config dir
# Every directory that could hold credentials or projects, most explicit first.
# '~' comes last: a shell the desktop app spawns does not always resolve it to
# the profile that holds the credentials.
function Get-ConfigDirCandidates {
    $roots = @()
    if ($env:CLAUDE_CONFIG_DIR) { $roots += $env:CLAUDE_CONFIG_DIR }
    foreach ($profileDir in @($env:USERPROFILE, $env:HOME)) {
        if ($profileDir) { $roots += (Join-Path $profileDir '.claude') }
    }
    try { $roots += (Join-Path (Resolve-Path '~' -ErrorAction Stop).Path '.claude') } catch { }
    $seen = @{}
    foreach ($root in $roots) {
        if (-not $root) { continue }
        $p = $root.TrimEnd('\', '/')
        $k = $p.ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $p }
    }
}

$configDirs = @(Get-ConfigDirCandidates)

# Which account is a given config dir logged in as. .claude.json sits beside the
# default dir but inside a custom CLAUDE_CONFIG_DIR, so probe both. -AsHashtable
# is required: that file has keys differing only in case and ConvertFrom-Json
# refuses it otherwise.
function Get-DirAccount([string]$dir) {
    foreach ($p in @((Join-Path $dir '.claude.json'), (Join-Path (Split-Path $dir -Parent) '.claude.json'))) {
        if (-not (Test-Path $p)) { continue }
        try { $o = Get-Content $p -Raw | ConvertFrom-Json -AsHashtable } catch { continue }
        $a = $o['oauthAccount']
        if ($a -and $a['accountUuid']) {
            return [ordered]@{ email = $a['emailAddress']; account_uuid = $a['accountUuid']; organization_uuid = $a['organizationUuid'] }
        }
    }
    # Weaker fallback: the credentials file carries the org but not the account.
    $cp = Join-Path $dir '.credentials.json'
    if (Test-Path $cp) {
        try {
            $o = Get-Content $cp -Raw | ConvertFrom-Json
            if ($o.organizationUuid) {
                return [ordered]@{ email = $null; account_uuid = $null; organization_uuid = $o.organizationUuid }
            }
        } catch { }
    }
    return $null
}

function Test-SameAccount($a, $b) {
    if (-not $a -or -not $b) { return $false }
    if ($a.account_uuid -and $b.account_uuid) { return $a.account_uuid -eq $b.account_uuid }
    # Only orgs known: a weaker match, but it still separates two logins.
    if ($a.organization_uuid -and $b.organization_uuid) { return $a.organization_uuid -eq $b.organization_uuid }
    return $false
}

function Format-Account($a) {
    if (-not $a) { return 'unknown' }
    if ($a.email) { return $a.email }
    if ($a.account_uuid) { return "account $($a.account_uuid)" }
    return "org $($a.organization_uuid)"
}

# ------------------------------------------------------------ host-managed auth
# The host - desktop app or Agent SDK - keeps the session's token in memory and
# passes it over IPC. These variables are it saying so. When one is set and no
# CLAUDE_CODE_OAUTH_TOKEN was exported, nothing on disk is this session's token,
# no matter how many credentials files exist or which account they name.
function Test-HostManagedAuth {
    return [bool]($env:CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH -or
                  $env:CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH -or
                  $env:CLAUDE_CODE_MESSAGING_SOCKET)
}

# --------------------------------------------------------------------- context
# Runs before the limits half: the session's owner decides which config dir is
# asked for a token.

$id = if ($SessionId) { $SessionId } else { $env:CLAUDE_CODE_SESSION_ID }
$out.session_id = $id

function Find-LatestUsage([string[]]$lines) {
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ([string]::IsNullOrWhiteSpace($lines[$i])) { continue }
        try { $o = $lines[$i] | ConvertFrom-Json } catch { continue }
        if ($o.type -ne 'assistant' -or -not $o.message.usage) { continue }
        # A sidechain entry is a subagent's turn, not this session's context.
        # Subagents normally get their own transcript file, but an interleaved
        # one would otherwise read as the session suddenly shrinking.
        if ($o.isSidechain) { continue }
        # Aborts and API errors are written as assistant turns carrying an
        # all-zero usage block. Taking one reports the context as empty.
        if ($o.isApiErrorMessage) { continue }
        $u = $o.message.usage
        $in = [int]$u.input_tokens + [int]$u.cache_creation_input_tokens + [int]$u.cache_read_input_tokens
        if ($in -le 0) { continue }
        # Output counts too: the reply is part of what the next request sends.
        # What this still misses is whatever landed after that reply - the tool
        # results and user turn since - so a reading trails by one turn.
        return [ordered]@{
            prompt = $in
            output = [int]$u.output_tokens
            total  = $in + [int]$u.output_tokens
            model  = $o.message.model
        }
    }
    return $null
}

# The account the session itself runs as. Only bridge-session entries carry the
# stamp - roughly a third of transcripts have one - and they sit anywhere in the
# file, so neither head nor tail is a safe shortcut. Prefilter on the substring
# so the full scan stays cheap, and parse only the lines that can match.
function Find-SessionOwner([string]$path) {
    $hits = @(Select-String -Path $path -SimpleMatch '"ownerAccountUuid"' -ErrorAction SilentlyContinue)
    for ($i = $hits.Count - 1; $i -ge 0; $i--) {
        try { $o = $hits[$i].Line | ConvertFrom-Json } catch { continue }
        if ($o.ownerAccountUuid) {
            return [ordered]@{ email = $null; account_uuid = $o.ownerAccountUuid; organization_uuid = $o.ownerOrganizationUuid }
        }
    }
    return $null
}

# The desktop app leaves no owner stamp and its token never touches disk, so the
# account check had nothing to compare and the reading was refused. It does leave
# one signal: it runs each session in a scratch workspace whose own path names the
# account and organization it is signed in as.
#   ...\Claude\scratch-workspaces\<accountUuid>\<organizationUuid>\scratch-<date>-<id>
# Reading that turns the app case from "cannot tell whose limits these would be"
# into a decidable comparison against the stored login, with nothing for the user
# to mint or configure. The layout is undocumented, so match it strictly: a change
# to it makes this return null, which falls back to the refusal rather than to a
# guess. Measured on 2026-09-21; the uuids matched the credentials file exactly.
function Get-AccountFromWorkspacePath([string]$cwd) {
    if (-not $cwd) { return $null }
    $u = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    if ($cwd -match "[\\/]scratch-workspaces[\\/]($u)[\\/]($u)(?:[\\/]|$)") {
        return [ordered]@{ email = $null; account_uuid = $Matches[1]; organization_uuid = $Matches[2] }
    }
    return $null
}

# cwd is stamped on most entries, so the head of the file is enough and keeps this
# cheap on a transcript that may be very long.
function Find-SessionCwd([string]$path) {
    foreach ($line in (Get-Content $path -TotalCount 200)) {
        if ($line -notlike '*"cwd"*') { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.cwd) { return $o.cwd }
    }
    return $null
}

$sessionOwner = $null
$transcript = $null

if (-not $id) {
    $out.context_error = 'no session id (CLAUDE_CODE_SESSION_ID unset and no -SessionId given)'
}
else {
    $projectDirs = @($configDirs | ForEach-Object { Join-Path $_ 'projects' })
    $transcript = $projectDirs |
        Where-Object { Test-Path $_ } |
        ForEach-Object { Get-ChildItem $_ -Recurse -Filter "$id.jsonl" -ErrorAction SilentlyContinue } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $transcript) {
        $out.context_error = "no transcript for session $id under [$($projectDirs -join '; ')]"
    }
    else {
        # Newest main-chain assistant usage block is the live occupancy:
        # absolute, not cumulative, so it drops after a compaction. The tail is
        # enough in practice; a long transcript is only read in full when it is
        # not - one turn writes several lines, and skipped entries add up.
        $u = Find-LatestUsage (Get-Content $transcript.FullName -Tail 400)
        if ($null -eq $u) { $u = Find-LatestUsage (Get-Content $transcript.FullName) }
        # Owner stamp first - it is explicit. The workspace path is the fallback
        # that makes desktop-app sessions decidable at all.
        $sessionOwner = Find-SessionOwner $transcript.FullName
        if (-not $sessionOwner) {
            $sessionOwner = Get-AccountFromWorkspacePath (Find-SessionCwd $transcript.FullName)
        }
        if ($null -eq $u) {
            $out.context_error = "no assistant message with usage yet in session $id"
        }
        else {
            $out.session_context_tokens = $u.total
            $out.session_model = $u.model
            $out.context_breakdown = [ordered]@{ prompt = $u.prompt; output = $u.output }
            if ($ContextWindow -gt 0) {
                $out.context_window = $ContextWindow
                $out.context_window_source = 'parameter'
                # A count above the window is impossible, so the window is wrong.
                # Dividing anyway would report a confident fraction of the wrong
                # denominator - the failure this field exists to make visible.
                if ($u.total -gt $ContextWindow) {
                    $out.context_error = "session_context_tokens ($($u.total)) exceeds the -ContextWindow passed ($ContextWindow), so that window is wrong; no percentage emitted. Pass this session's real window."
                }
                else {
                    $out.session_context_percent = [Math]::Round(100.0 * $u.total / $ContextWindow, 1)
                }
            }
            else {
                # Deliberately no percentage: the window is recorded nowhere this
                # script can read, and one model id runs at both 200K and 1M.
                $out.context_window_source = 'unknown'
            }
        }
    }
}

if ($sessionOwner) { $out.session_account = $sessionOwner }

# ------------------------------------------------------- config dir + token
# Order the candidates so a dir logged in as the session's own account is asked
# first. Without this the first dir holding any token wins, which on a
# two-account machine is a coin flip resolved silently.

$dirAccounts = @{}
foreach ($d in $configDirs) { $dirAccounts[$d] = Get-DirAccount $d }

$matching = @($configDirs | Where-Object { Test-SameAccount $dirAccounts[$_] $sessionOwner })
$orderedDirs = @($matching) + @($configDirs | Where-Object { $_ -notin $matching })

# The first candidate that actually holds Claude state, not merely the first
# that exists: an empty CLAUDE_CONFIG_DIR must not be reported as the one in use.
$out.config_dir = @($orderedDirs | Where-Object {
    (Test-Path (Join-Path $_ '.credentials.json')) -or (Test-Path (Join-Path $_ 'projects'))
}) | Select-Object -First 1

# Each returns @{ token; source; expires; account } or $null.

function Get-TokenFromEnv {
    # The pinned token comes first. It is this script's own: Claude Code does not
    # read CLAUDE_USAGE_OAUTH_TOKEN, so it can be set machine-wide - which is what
    # makes a GUI surface work - without moving any session onto its account.
    if ($env:CLAUDE_USAGE_OAUTH_TOKEN) {
        return @{ token = $env:CLAUDE_USAGE_OAUTH_TOKEN; source = 'env:CLAUDE_USAGE_OAUTH_TOKEN'; expires = $null; account = $null; pinned = $true }
    }
    # Honoured second, for a machine that already has one set for CI. Not the
    # variable to recommend: Claude Code authenticates with it too.
    if ($env:CLAUDE_CODE_OAUTH_TOKEN) {
        return @{ token = $env:CLAUDE_CODE_OAUTH_TOKEN; source = 'env:CLAUDE_CODE_OAUTH_TOKEN'; expires = $null; account = $null; pinned = $false }
    }
    return $null
}

# The one-time setup, stated exactly, because this text is the entire answer when
# a session can read no token. The obvious advice - export CLAUDE_CODE_OAUTH_TOKEN
# - is wrong twice over: a shell export never reaches a GUI app's environment, and
# that variable also authenticates Claude Code itself.
function Get-SetupHelp {
    $mint = "run 'claude setup-token' in a terminal, logged in as the account you want measured, and copy the token it prints (it is saved nowhere)"
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        return "$mint. Then set it as a persistent user variable: setx CLAUDE_USAGE_OAUTH_TOKEN ""<token>"". Restart the app or editor afterwards - a process reads the user environment only at launch."
    }
    if ($IsMacOS) {
        # A GUI app on macOS is launched by launchd, not by a shell, so a profile
        # export reaches the terminal only.
        return "$mint. For terminal sessions add 'export CLAUDE_USAGE_OAUTH_TOKEN=<token>' to your shell profile; for the desktop app also run 'launchctl setenv CLAUDE_USAGE_OAUTH_TOKEN <token>' and restart it, since a GUI app is launched by launchd and never reads your profile."
    }
    return "$mint. Then add 'export CLAUDE_USAGE_OAUTH_TOKEN=<token>' to your shell profile, and to your desktop session's environment (~/.config/environment.d/ or similar) if you use a GUI surface. Restart it afterwards."
}

function Get-TokenFromFile([string[]]$dirs) {
    foreach ($dir in $dirs) {
        $path = Join-Path $dir '.credentials.json'
        if (-not (Test-Path $path)) { continue }
        try { $oauth = (Get-Content $path -Raw | ConvertFrom-Json).claudeAiOauth } catch { continue }
        if ($oauth.accessToken) {
            $exp = if ($oauth.expiresAt) { [DateTimeOffset]::FromUnixTimeMilliseconds($oauth.expiresAt).LocalDateTime } else { $null }
            return @{ token = $oauth.accessToken; source = "file:$path"; expires = $exp; account = $dirAccounts[$dir] }
        }
    }
    return $null
}

function Get-TokenFromKeychain {
    # macOS keeps the login in the Keychain and writes no credentials file, so
    # the file probe finds nothing there however many profiles it tries.
    if (-not $IsMacOS) { return $null }
    try {
        $raw = & security find-generic-password -a $env:USER -w -s 'Claude Code-credentials' 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
        $parsed = $raw | ConvertFrom-Json
        $oauth = $parsed.claudeAiOauth
        if ($oauth.accessToken) {
            $exp = if ($oauth.expiresAt) { [DateTimeOffset]::FromUnixTimeMilliseconds($oauth.expiresAt).LocalDateTime } else { $null }
            $acct = if ($parsed.organizationUuid) {
                [ordered]@{ email = $null; account_uuid = $null; organization_uuid = $parsed.organizationUuid }
            } else { $null }
            return @{ token = $oauth.accessToken; source = 'keychain:Claude Code-credentials'; expires = $exp; account = $acct }
        }
    } catch { }
    return $null
}

function Get-TokenFromHelper([string[]]$dirs) {
    # apiKeyHelper is the escape hatch for managed setups: a command that prints
    # a fresh token on stdout. Honour it the way the CLI does.
    foreach ($dir in $dirs) {
        foreach ($name in @('settings.local.json', 'settings.json')) {
            $path = Join-Path $dir $name
            if (-not (Test-Path $path)) { continue }
            try { $helper = (Get-Content $path -Raw | ConvertFrom-Json).apiKeyHelper } catch { continue }
            if (-not $helper) { continue }
            try {
                $token = (& pwsh -NoProfile -NonInteractive -Command $helper 2>$null | Out-String).Trim()
                if ($token) { return @{ token = $token; source = "apiKeyHelper:$path"; expires = $null; account = $dirAccounts[$dir] } }
            } catch { }
        }
    }
    return $null
}

$hostAuth = Test-HostManagedAuth
$out.auth_mode = if ($hostAuth) { 'host-managed' } else { 'local' }

# Whether a stored login exists at all, reported as its own field and separately
# from whether one was usable. A machine driven only through the desktop app or
# the extension can reach here having never written this file - both keep their
# credential in their own process - and then there is nothing to read rather than
# something being wrong. Saying which of the two it is turns "the skill is broken"
# into "this machine has no readable login", which is a different instruction to
# the reader and the only one of the two they can act on.
$out.credentials_file = @($configDirs | ForEach-Object { Join-Path $_ '.credentials.json' } |
    Where-Object { Test-Path $_ }) | Select-Object -First 1
$noCredentialsFile = -not $out.credentials_file

$auth = Get-TokenFromEnv
$fromEnv = [bool]$auth
if (-not $auth) { $auth = Get-TokenFromFile $orderedDirs }
if (-not $auth) { $auth = Get-TokenFromKeychain }
if (-not $auth) { $auth = Get-TokenFromHelper $orderedDirs }

# ------------------------------------------------------------ account check

$blocked = $false

# Host-managed auth with nothing exported: this session's own token is
# unreadable, and whatever sits on disk is some other login's with no owner stamp
# to disprove it. Refusing is the whole point - waving this case through is what
# reported one account's subscription as another's.
# The refusal exists because a host-managed session could not be tied to any
# account, so a stored token might silently be a different subscription's. When
# the session's account IS known - an owner stamp, or the desktop app's workspace
# path - and it matches the stored login, that doubt is gone and refusing would
# withhold a reading that is provably correct.
$ownerVerified = $sessionOwner -and $auth -and (Test-SameAccount $auth.account $sessionOwner)

# Only -RequireAccountMatch refuses now. Refusing by default was an overcorrection:
# it turned "cannot prove whose these are" into no reading at all, which silently
# broke every editor-extension session once Claude Code moved those to host-managed
# auth - the one surface where nothing on disk names the account. Unverifiable is
# not the same as wrong, and the guard that matters is naming the account beside the
# numbers so a wrong one is visible and can be rejected. Where a wrong number is
# worse than none, -RequireAccountMatch still refuses outright.
if ($RequireAccountMatch -and $auth -and -not $ownerVerified -and -not $UseStoredToken) {
    $blocked = $true
    $out.account = $auth.account
    $whose = Format-Account $auth.account
    $out.account_mismatch = "unverifiable, and -RequireAccountMatch was passed, so no limits were fetched. This session leaves no account signal - host-managed auth keeps its own token in the host, and only a desktop-app session names its account in its workspace path - so the stored login ($whose) could not be shown to be the same account. Drop -RequireAccountMatch to read it labelled, or $(Get-SetupHelp)"
    $out.limits_error = $out.account_mismatch
}

if ($auth -and -not $blocked) {
    $out.account = $auth.account
    if ($ownerVerified) {
        # Nothing to flag: the session's own account and the token's are the same
        # account, so null carries its documented meaning. Worth naming as its own
        # branch because a host-managed session reaching this point is exactly the
        # case that used to be refused for being undecidable.
        $out.account_mismatch = $null
    }
    elseif ($sessionOwner -and $auth.account -and -not (Test-SameAccount $auth.account $sessionOwner)) {
        # A KNOWN, DIFFERENT account. This must be tested before any of the
        # host-managed branches below, which describe the account as merely
        # unknown: a desktop-app session is host-managed AND names its account, so
        # ordering these the other way around reports the one case we can actually
        # prove wrong as if it were only unproven - the softest possible wording
        # for the loudest possible finding.
        $who = "the only token available belongs to $(Format-Account $auth.account), but this session runs as $(Format-Account $sessionOwner)"
        $out.account_mismatch = "$who. The limits below are the WRONG subscription's - do not report them as this session's. Log in as the session's account, or set CLAUDE_USAGE_OAUTH_TOKEN for it."
    }
    elseif ($hostAuth -and -not $fromEnv -and $UseStoredToken) {
        # The deliberate override: the caller asked for this account by name.
        $out.account_mismatch = "host-managed session: the limits below belong to $(Format-Account $auth.account), the stored CLI login, read because -UseStoredToken was passed. They are NOT provably this session's."
    }
    elseif ($hostAuth -and -not $fromEnv) {
        # The editor-extension and SDK case. The numbers are reported rather than
        # refused, so the label carries the whole warning: name the account, say
        # plainly that it is not proven, and say what would prove it.
        $out.account_mismatch = "unverified: this session is host-managed and names its account nowhere on disk, so the limits below cannot be tied to it. They are $(Format-Account $auth.account)'s - the CLI's login, which is the only thing that writes .credentials.json, and therefore a different lineage from whatever this session signed into. The same account on a single-account machine; wrong without warning on a machine with two. Check the account is the one you meant before acting on the numbers. To remove the doubt: $(Get-SetupHelp) Or pass -RequireAccountMatch to refuse rather than report when it cannot be proven."
    }
    elseif ($auth.pinned) {
        # The intended path. Nothing local names the account behind a minted
        # token, but it was minted for one on purpose, so this is a note about
        # which subscription is being measured - not a warning about the reading.
        $out.account_mismatch = 'pinned: these are the limits of whichever account CLAUDE_USAGE_OAUTH_TOKEN was minted for. Nothing local names it, so confirm once that it is the subscription you meant; after that it is the same account on every surface.'
    }
    elseif ($auth.source -eq 'env:CLAUDE_CODE_OAUTH_TOKEN') {
        $out.account_mismatch = 'unverifiable: CLAUDE_CODE_OAUTH_TOKEN names no account, and it is also an authentication source for Claude Code itself, so it may have been set for something other than usage reporting. Set CLAUDE_USAGE_OAUTH_TOKEN to pin the account measured here instead.'
    }
    elseif ($sessionOwner -and -not $auth.account) {
        $out.account_mismatch = 'unverifiable: no .claude.json names the account behind this token, so it cannot be matched against the session.'
    }
    elseif (-not $sessionOwner) {
        # The common case: most transcripts carry no owner stamp. Say so, and
        # name the account anyway - a labelled number the reader can reject
        # beats an unlabelled one they cannot.
        $out.account_mismatch = "unverifiable: this session's transcript carries no owner stamp, so the token cannot be matched against it. The limits below are $(Format-Account $auth.account)'s - check that is the account you meant. Setting CLAUDE_USAGE_OAUTH_TOKEN for the account you want measured removes the doubt."
    }
}

# ---------------------------------------------------------------------- limits

if (-not $auth) {
    $searched = $configDirs -join '; '
    # A base URL only means third-party when it points somewhere other than the
    # real API. The desktop app exports ANTHROPIC_BASE_URL=https://api.anthropic.com
    # for its own sessions, and treating that as a gateway masked the real cause.
    $thirdParty = $false
    if ($env:ANTHROPIC_BASE_URL) {
        try { $thirdParty = ([Uri]$env:ANTHROPIC_BASE_URL).Host -notmatch '(^|\.)anthropic\.com$' } catch { $thirdParty = $true }
    }
    $out.limits_error = if ($env:ANTHROPIC_API_KEY -or $env:ANTHROPIC_AUTH_TOKEN -or $thirdParty) {
        "API-key or third-party-provider auth: no subscription limits exist for it, because a key has no subscription. To read one anyway, $(Get-SetupHelp)"
    } elseif ($noCredentialsFile) {
        # The distinct, actionable state: nothing to read, as opposed to something
        # read and rejected. Lead with it so it is not mistaken for a malfunction.
        "NO STORED LOGIN ON THIS MACHINE: no .credentials.json exists under [$searched], and no token is set in the environment, so there is no subscription for this script to query. Nothing is broken - the desktop app and the editor extension each keep their login inside their own process and never write this file, so a machine used only through them has none. Context size below is unaffected and still accurate. To make limits readable, either sign in once from a terminal ('claude' and /login), which writes the file every surface can then share, or $(Get-SetupHelp)"
    } elseif ($hostAuth) {
        "host-managed auth (auth_mode=host-managed) and no usable token: this session's credentials live in its host - the desktop app, the editor extension or an SDK harness - and the stored login under [$searched] could not be used. $(Get-SetupHelp)"
    } else {
        "no OAuth token. Searched CLAUDE_USAGE_OAUTH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN, .credentials.json under [$searched], the macOS keychain and apiKeyHelper. $(Get-SetupHelp)"
    }
}
elseif (-not $blocked) {
    $out.auth_source = $auth.source
    # An expired stored token is still worth sending: clocks skew, and the CLI
    # may have refreshed the file since it was read. A real 401 says so below.
    try {
        $r = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Method Get -Headers @{
            'Authorization'  = "Bearer $($auth.token)"
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
            $lim = [double]$r.spend.limit.amount_minor / $div
            $out.credits = [ordered]@{
                used     = [double]$r.spend.used.amount_minor / $div
                # A zero limit is "no monthly cap set", not a cap of nothing.
                # Emitting 0.0 reads as spend against an exhausted budget and
                # invites "94.14 of 0.00", so say unlimited explicitly instead.
                limit    = if ($lim -gt 0) { $lim } else { $null }
                unlimited = ($lim -le 0)
                currency = $r.spend.used.currency
            }
        }
    }
    catch {
        $status = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        $out.limits_error = switch ($status) {
            429 { 'rate limited (429) - treat as unchanged since the last reading and retry later' }
            401 {
                # A pinned token is not refreshed by anything: it is a copied
                # string, so the only fix is to mint another and reset the
                # variable. Telling the user to run a claude command would send
                # them to refresh a credential this reading never touched.
                if ($auth.source -like 'env:*') {
                    "unauthorized (401) from $($auth.source) - that token is invalid, revoked, or past its one-year life. Mint a new one and set the variable again: $(Get-SetupHelp)"
                }
                else {
                    $when = if ($auth.expires) { " (stored token expired $($auth.expires))" } else { '' }
                    "unauthorized (401)$when from $($auth.source) - run any interactive claude command to refresh it, or pin one instead: $(Get-SetupHelp)"
                }
            }
            403 { "forbidden (403) from $($auth.source) - the token lacks the subscription scope" }
            default { $_.Exception.Message }
        }
    }
}

$out | ConvertTo-Json -Depth 6
