<#
.SYNOPSIS
Read-only survey of cleanup candidates for the cleanup skill, as JSON.

.DESCRIPTION
Collects, without changing anything: merged and stale branches, worktrees, non-version
tags, scratch files in the worktree root, dead info/exclude entries, tracked plan-like
files, ADR index inconsistencies, memory index inconsistencies, and em/en dashes plus
comment smells in the lines this branch adds over origin/main.

Run from anywhere inside the repository under pwsh 7. Sections whose inputs a repo
lacks (no docs/adr, no memory dir, no dash rule) come back empty, never as errors.

.PARAMETER MemoryDir
The agent's memory directory (from the system prompt). Derived from the repo path when
omitted; that derivation fails for a worktree whose path is not the session's project.

.PARAMETER BaseRef
The ref the branch diff is taken against. Default origin/main.
#>
[CmdletBinding()]
param(
    [string]$MemoryDir,
    [string]$BaseRef = 'origin/main'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# Named Git for readability; the body must call the executable, not this function.
$gitExe = (Get-Command git -CommandType Application | Select-Object -First 1).Source
function Git { param([Parameter(ValueFromRemainingArguments)][string[]]$Args) & $gitExe @Args 2>$null }

$root = (Git rev-parse --show-toplevel)
if (-not $root) { throw 'not inside a git repository' }
Set-Location $root
$gitDir = (Git rev-parse --git-common-dir)
if (-not [IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $root $gitDir }

$out = [ordered]@{
    repo_root = $root
    branch    = (Git branch --show-current)
    base_ref  = $BaseRef
    git       = [ordered]@{}
    repo      = [ordered]@{}
    memory    = [ordered]@{}
    diff      = [ordered]@{}
}

# ---------------------------------------------------------------------------- git

$worktrees = @()
$current = $null
foreach ($line in (Git worktree list --porcelain)) {
    if ($line -like 'worktree *') { $current = [ordered]@{ path = $line.Substring(9); branch = $null; bare = $false; detached = $false } ; $worktrees += $current }
    elseif ($line -like 'branch *') { $current.branch = $line.Substring(7) -replace '^refs/heads/', '' }
    elseif ($line -eq 'detached') { $current.detached = $true }
    elseif ($line -eq 'bare') { $current.bare = $true }
}
foreach ($wt in $worktrees) {
    $wt.exists = Test-Path $wt.path
    $wt.clean = if ($wt.exists) { -not (Git -C $wt.path status --porcelain) } else { $null }
}
$out.git.worktrees = $worktrees
$checkedOut = @($worktrees | ForEach-Object { $_.branch } | Where-Object { $_ })

$mergedRaw = @(Git branch --merged $BaseRef --format='%(refname:short)')
$branches = @()
foreach ($b in (Git for-each-ref refs/heads --format='%(refname:short)|%(upstream:short)|%(upstream:track)')) {
    $name, $upstream, $track = $b.Split('|')
    $branches += [ordered]@{
        name             = $name
        upstream         = if ($upstream) { $upstream } else { $null }
        upstream_gone    = ($track -eq '[gone]')
        merged_into_main = ($mergedRaw -contains $name) -and ($name -ne 'main')
        checked_out      = ($checkedOut -contains $name)
        orchestration    = ($name -like 'orchestration-state*')
    }
}
$out.git.branches = $branches
$out.git.non_version_tags = @(Git tag | Where-Object { $_ -notmatch '^v\d+\.\d+\.\d+' })

$scratchPatterns = '*.scratch.md', 'ORCHESTRATION*', 'HANDOFF*', '*DECISIONS*.md', 'NEXT-SESSION*', '*CHECKPOINT*.md', '*.ARCHIVE'
$rootFiles = Get-ChildItem $root -File -Force | Where-Object { $f = $_; ($scratchPatterns | Where-Object { $f.Name -like $_ }).Count -gt 0 }
$out.git.scratch_files = @($rootFiles | ForEach-Object {
    $rel = $_.Name
    [ordered]@{ path = $rel; tracked = [bool](Git ls-files --error-unmatch $rel); last_write = $_.LastWriteTime.ToString('s') }
})

$excludePath = Join-Path $gitDir 'info/exclude'
$dead = @()
if (Test-Path $excludePath) {
    foreach ($line in Get-Content $excludePath) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#') -or $t.StartsWith('!') -or $t.Contains('*') -or $t.EndsWith('/')) { continue }
        $candidate = Join-Path $root ($t.TrimStart('/'))
        if (-not (Test-Path $candidate)) { $dead += $t }
    }
}
$out.git.exclude_file = $excludePath
$out.git.dead_exclude_entries = $dead

# --------------------------------------------------------------------------- repo

$out.repo.tracked_plan_files = @(Git ls-files | Where-Object { $_ -match '(^|/)(PLAN|HANDOFF|ORCHESTRATION|BACKLOG|TODO|NEXT-SESSION|CHECKPOINT)[^/]*\.md$' })

$adr = [ordered]@{ file_without_index_row = @(); index_row_without_file = @(); status_mismatch = @(); implementation_mismatch = @(); superseded_without_banner = @(); template_copies = @() }
$adrDir = Join-Path $root 'docs/adr'
if (Test-Path (Join-Path $adrDir 'README.md')) {
    $rows = @{}
    foreach ($line in Get-Content (Join-Path $adrDir 'README.md')) {
        if ($line -match '^\|\s*\[(\d{4})\]\(([^)]+)\)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|') {
            $rows[$Matches[1]] = [ordered]@{ file = $Matches[2]; title = $Matches[3]; status = $Matches[4]; implementation = $Matches[5] }
        }
    }
    $files = Get-ChildItem $adrDir -File -Filter '*.md' | Where-Object { $_.Name -match '^\d{4}-' }
    foreach ($f in $files) {
        $num = $f.Name.Substring(0, 4)
        $text = Get-Content $f.FullName -Raw
        $status = if ($text -match '(?m)^- Status:\s*(.+?)\s*$') { $Matches[1] } else { $null }
        $impl = if ($text -match '(?m)^- Implementation:\s*(.+?)\s*$') { $Matches[1] } else { $null }
        if ($text -match 'Short title of the decision|What forces the decision\?') { $adr.template_copies += $f.Name }
        if (-not $rows.ContainsKey($num)) { $adr.file_without_index_row += $f.Name; continue }
        $row = $rows[$num]
        if ($status -and ($row.status -ne $status)) { $adr.status_mismatch += [ordered]@{ adr = $num; index = $row.status; file = $status } }
        # The index keeps the short form; a parenthetical detail in the file is not a mismatch.
        $implShort = $impl -replace '\s*\(.*\)\s*$', ''
        if ($impl -and (($row.implementation -replace '\s*\(.*\)\s*$', '') -ne $implShort)) { $adr.implementation_mismatch += [ordered]@{ adr = $num; index = $row.implementation; file = $impl } }
        if ($status -like 'Superseded*' -and $text -notmatch 'SUPERSEDED BY') { $adr.superseded_without_banner += $f.Name }
    }
    foreach ($num in $rows.Keys) {
        if (-not (Test-Path (Join-Path $adrDir $rows[$num].file))) { $adr.index_row_without_file += [ordered]@{ adr = $num; file = $rows[$num].file } }
    }
}
$out.repo.adr = $adr

# ------------------------------------------------------------------------- memory

if (-not $MemoryDir) {
    $slug = ($root -replace '[^A-Za-z0-9]', '-')
    $claudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path (Resolve-Path '~').Path '.claude' }
    foreach ($s in @($slug, $slug.Substring(0, 1).ToLower() + $slug.Substring(1), $slug.Substring(0, 1).ToUpper() + $slug.Substring(1))) {
        $p = Join-Path $claudeHome "projects/$s/memory"
        if (Test-Path $p) { $MemoryDir = $p; break }
    }
}
$mem = [ordered]@{ dir = $MemoryDir; index_without_file = @(); file_without_index = @(); status_language = @(); dangling_paths = @() }
if ($MemoryDir -and (Test-Path $MemoryDir)) {
    $indexPath = Join-Path $MemoryDir 'MEMORY.md'
    $indexed = @()
    if (Test-Path $indexPath) {
        foreach ($line in Get-Content $indexPath) {
            if ($line -match '\]\(([^)]+\.md)\)') {
                $indexed += $Matches[1]
                if (-not (Test-Path (Join-Path $MemoryDir $Matches[1]))) { $mem.index_without_file += $Matches[1] }
            }
        }
    }
    foreach ($f in Get-ChildItem $MemoryDir -File -Filter '*.md') {
        if ($f.Name -eq 'MEMORY.md') { continue }
        if ($indexed -notcontains $f.Name) { $mem.file_without_index += $f.Name }
        $text = Get-Content $f.FullName -Raw
        $hits = [regex]::Matches($text, '(?i)\b(still owed|not yet (merged|opened|done)|pending|in flight|only the PR|TODO|next step)\b') | ForEach-Object { $_.Value } | Select-Object -Unique
        if ($hits) { $mem.status_language += [ordered]@{ file = $f.Name; phrases = @($hits) } }
        $paths = [regex]::Matches($text, '`((?:[A-Za-z]:\\|~[\\/]|\.{0,2}[\\/])[^`\s]+)`') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
        $userHome = (Resolve-Path '~').Path
        foreach ($pth in $paths) {
            $resolved = $pth -replace '^~', $userHome
            if ($resolved -match '[*?]') { continue }
            # Only paths on this machine can be checked; a memory about a remote box names paths that exist there.
            $local = $resolved.StartsWith($userHome, 'OrdinalIgnoreCase') -or $resolved.StartsWith($root, 'OrdinalIgnoreCase') -or -not [IO.Path]::IsPathRooted($resolved)
            if (-not $local) { continue }
            if (-not (Test-Path $resolved) -and -not (Test-Path (Join-Path $root $resolved))) { $mem.dangling_paths += [ordered]@{ file = $f.Name; path = $pth } }
        }
    }
}
$out.memory = $mem

# --------------------------------------------------------------------------- diff

$dashPattern = "[`u{2013}`u{2014}]"
if ('a' + [char]0x2014 + 'b' -notmatch $dashPattern) { throw 'dash pattern failed its positive control' }
# Internal references are welcome in comments and XML docs; only operator-visible text may not cite them.
$smellPattern = '(?i)\b(fix(es|ed)? for|workaround for|we found|found that|PR #\d+|#\d{3,}\b|ticket|TODO|FIXME|HACK|for now|temporar(y|ily)|this (task|change|session|PR))\b'
$uiReferencePattern = '"[^"]*\b(ADR|PR|issue) ?#?\d{2,}[^"]*"|<value>[^<]*\b(ADR|PR|issue) ?#?\d{2,}'
$commentStart = '^\+\s*(//|#(?!region|endregion|if|else|endif|pragma|nullable)|<!--|/\*|\*)'
$plainComment = '^\+\s*//(?!/)|^\+\s*#(?!region|endregion|if|else|endif|pragma|nullable)'
$codeShape = '^\s*//\s*(var |return |if \(|foreach |using |[\w.<>\[\]]+\s*=[^=>]|[\w.<>\[\]]+\(.*\);\s*$|[\w.<>\[\]]+;\s*$)'

# Dashes are a house rule, not a defect: scan for them only when the repo's own instructions forbid them.
$dashRuleSource = $null
foreach ($name in 'AGENTS.md', 'CLAUDE.md', '.github/copilot-instructions.md') {
    $f = Join-Path $root $name
    if ((Test-Path $f) -and ((Get-Content $f -Raw) -match '(?i)\bem[- ]?dash')) { $dashRuleSource = $name; break }
}

$diff = [ordered]@{ dash_rule_source = $dashRuleSource; dashes = @(); comment_smells = @(); ui_text_references = @(); long_comment_blocks = @(); commented_out_code = @() }
if (-not $dashRuleSource) { $diff.dashes_skipped = 'no rule against dashes in AGENTS.md, CLAUDE.md or copilot-instructions.md' }
$mergeBase = Git merge-base $BaseRef HEAD
if ($mergeBase) {
    $file = $null; $run = 0; $runStart = $null
    foreach ($line in (Git diff -U0 --diff-filter=AM "$mergeBase..HEAD" -- . ':!*.verified.txt' ':!*.png' ':!*.svg' ':!*.ico')) {
        if ($line -like '+++ b/*') { $file = $line.Substring(6); $run = 0; continue }
        if ($line -like '---*' -or $line -like 'diff --git*' -or $line -like 'index *') { continue }
        if ($line -like '@@*') { $run = 0; continue }
        if (-not $line.StartsWith('+')) { continue }
        $content = $line.Substring(1)
        if ($dashRuleSource -and $content -match $dashPattern) { $diff.dashes += [ordered]@{ file = $file; line = $content.Trim() } }
        if ($content -match $uiReferencePattern) { $diff.ui_text_references += [ordered]@{ file = $file; line = $content.Trim() } }
        if ($line -match $commentStart) {
            if ($content -match $smellPattern) { $diff.comment_smells += [ordered]@{ file = $file; line = $content.Trim(); smell = $Matches[1] } }
            # XML doc blocks are allowed to run long; only plain // and # runs count as narration.
            if ($line -match $plainComment) {
                $run++
                if ($run -eq 1) { $runStart = $content.Trim() }
                if ($run -eq 4) { $diff.long_comment_blocks += [ordered]@{ file = $file; starts = $runStart } }
                if ($content -match $codeShape -and $content -notmatch 'Copyright') { $diff.commented_out_code += [ordered]@{ file = $file; line = $content.Trim() } }
            }
            else { $run = 0 }
        }
        else { $run = 0 }
    }
}
else { $diff.error = "no merge base with $BaseRef" }
$out.diff = $diff

$out | ConvertTo-Json -Depth 8

# A failed git probe (no merge base, no upstream) must not leak its exit code to the caller.
exit 0
