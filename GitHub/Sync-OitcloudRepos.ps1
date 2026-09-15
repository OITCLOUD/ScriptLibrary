<#
.SYNOPSIS
    Clones and fast-forwards every non-archived repository in the OITCLOUD GitHub org.

.DESCRIPTION
    Safe mirror of an entire GitHub organization onto a local folder, intended for an
    unattended scheduled task.

    Per repository:
      - not present locally          -> git clone (default branch)
      - present, clean, behind       -> git fetch --prune + git merge --ff-only
      - present, clean, up to date   -> reported CURRENT, nothing done
      - present, clean, ahead        -> fetched only, reported AHEAD (you have unpushed work)
      - present, dirty               -> fetched only, reported SKIP-DIRTY, working tree untouched
      - present, diverged / detached -> fetched only, reported SKIP, working tree untouched
      - present locally, gone from org -> reported ORPHAN, never deleted

    The script NEVER runs reset, checkout, clean, stash, rebase or merge other than
    --ff-only. It cannot destroy local work by design.

    Authentication uses a DPAPI-encrypted PAT written by Set-OitcloudSyncToken.ps1.
    The token is handed to git through a per-run GIT_ASKPASS shim and a process-scoped
    environment variable. It is never written to .git/config, never placed in a remote
    URL, and never appears on a command line.

.PARAMETER RepoRoot
    Local folder that holds one subfolder per repository. Created if missing.
    Default: C:\GITWork - the existing Office-IT convention (see the Veeam pipeline
    page in BookStack), so repositories already cloned there are adopted rather
    than duplicated.

.PARAMETER TokenPath
    DPAPI-encrypted token file written by Set-OitcloudSyncToken.ps1.

.PARAMETER LogDirectory
    Folder for per-run log files. The newest 30 are kept.

.PARAMETER Organization
    GitHub organization. Default: OITCLOUD

.PARAMETER IncludeArchived
    Also sync archived repositories. Off by default.

.PARAMETER ExcludeRepo
    One or more repository names to skip.

.EXAMPLE
    .\Sync-OitcloudRepos.ps1 -Verbose

.EXAMPLE
    .\Sync-OitcloudRepos.ps1 -WhatIf

.NOTES
    Author       : Office-IT
    Requires     : Windows PowerShell 5.1, git for Windows on PATH
    Encoding     : ASCII (no BOM)
    Exit codes   : 0 = no failures (skips are allowed and reported)
                   1 = fatal error, nothing or little was synced
                   2 = completed, but one or more repositories failed
    Verification : see the VERIFY block at the end of this file
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RepoRoot = 'C:\GITWork',
    [string]$TokenPath = (Join-Path $env:LOCALAPPDATA 'Office-IT\GitHubSync\oitcloud-token.sec'),
    [string]$LogDirectory = (Join-Path $env:LOCALAPPDATA 'Office-IT\GitHubSync\logs'),
    [string]$Organization = 'OITCLOUD',
    [switch]$IncludeArchived,
    [string[]]$ExcludeRepo = @(),
    [int]$KeepLogs = 30
)

$ErrorActionPreference = 'Stop'

$script:LogFile = $null
$script:AskPassFile = $null
$script:TokenExpiryRaw = $null

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Output $line
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line -Encoding ASCII
    }
}

function Read-DataFile {
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
    if ($null -eq $raw) { return $null }

    # Strip a UTF-8 BOM if present. Trim() will not remove U+FEFF.
    $bom = [char]0xFEFF
    while ($raw.Length -gt 0 -and $raw[0] -eq $bom) {
        $raw = $raw.Substring(1)
    }

    return $raw.Trim()
}

function ConvertFrom-SecureStringPlain {
    param([Parameter(Mandatory)][System.Security.SecureString]$Secure)

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Invoke-Git {
    <#
        Runs git and returns ExitCode + combined output.
        $ErrorActionPreference is forced to Continue inside this function: git writes
        progress to stderr, and with 2>&1 under 'Stop' PowerShell 5.1 turns that into
        a terminating NativeCommandError.
    #>
    param(
        [string]$WorkDir,
        [Parameter(Mandatory)][string[]]$GitArgs
    )

    $ErrorActionPreference = 'Continue'

    $prev = (Get-Location).Path
    try {
        if ($WorkDir) { Set-Location -LiteralPath $WorkDir }
        $raw = & git @GitArgs 2>&1
        $code = $LASTEXITCODE
        $text = (@($raw) | ForEach-Object { $_.ToString() }) -join "`r`n"
        return [pscustomobject]@{
            ExitCode = $code
            Output   = $text.Trim()
        }
    }
    finally {
        Set-Location -LiteralPath $prev
    }
}

function New-AskPassShim {
    param([Parameter(Mandatory)][string]$Directory)

    $path = Join-Path $Directory ('oitsync-askpass-{0}.cmd' -f $PID)

    # Git calls this once for the username and once for the password.
    # The token itself lives only in the OITSYNC_GH_TOKEN process env var.
    $lines = @(
        '@echo off',
        'echo.%~1| findstr /i "Username" >nul',
        'if %errorlevel%==0 (',
        '  echo x-access-token',
        ') else (',
        '  echo %OITSYNC_GH_TOKEN%',
        ')'
    )
    Set-Content -Path $path -Value ($lines -join "`r`n") -Encoding ASCII
    return $path
}

function Get-OrgRepository {
    param(
        [Parameter(Mandatory)][string]$Org,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $all = @()
    $uri = 'https://api.github.com/orgs/{0}/repos?per_page=100&type=all&sort=full_name' -f $Org
    $page = 0

    while ($uri) {
        $page++
        $resp = Invoke-WebRequest -Uri $uri -Headers $Headers -Method Get -UseBasicParsing -ErrorAction Stop
        $batch = $resp.Content | ConvertFrom-Json
        if ($batch) { $all += @($batch) }

        # GitHub returns the PAT expiry on every API response for fine-grained tokens.
        if ($page -eq 1) {
            $script:TokenExpiryRaw = $resp.Headers['GitHub-Authentication-Token-Expiration']
        }

        $uri = $null
        $link = $resp.Headers['Link']
        if ($link) {
            foreach ($part in ($link -split ',')) {
                if ($part -match '<([^>]+)>;\s*rel="next"') {
                    $uri = $Matches[1]
                    break
                }
            }
        }
        if ($page -gt 50) { throw 'Aborting repository enumeration after 50 pages.' }
    }

    return $all
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$results = @()
$fatal = $false
$startedAt = Get-Date

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }
    $script:LogFile = Join-Path $LogDirectory ('sync-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

    Write-Log ('=== OITCLOUD repo sync starting ===')
    Write-Log ('Account      : {0}\{1} on {2}' -f $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME)
    Write-Log ('Repo root    : {0}' -f $RepoRoot)
    Write-Log ('Log file     : {0}' -f $script:LogFile)
    Write-Log ('PS version   : {0}' -f $PSVersionTable.PSVersion.ToString())
    if ($WhatIfPreference) { Write-Log 'Running in -WhatIf mode: no clone, fetch or merge will be performed.' 'WARN' }

    # --- Preconditions ------------------------------------------------------
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCmd) { throw 'git was not found on PATH. Install Git for Windows.' }
    $gitVer = Invoke-Git -GitArgs @('--version')
    Write-Log ('Git          : {0}' -f $gitVer.Output)

    if (-not (Test-Path -LiteralPath $TokenPath)) {
        throw ('Token file not found: {0}. Run Set-OitcloudSyncToken.ps1 first, as this same account.' -f $TokenPath)
    }

    try {
        $secure = Read-DataFile -Path $TokenPath | ConvertTo-SecureString -ErrorAction Stop
    }
    catch {
        throw ('Token file {0} could not be decrypted by {1}\{2} on {3}. DPAPI blobs are bound to the user AND the machine that created them. Re-run Set-OitcloudSyncToken.ps1 as this account. Inner error: {4}' -f `
                $TokenPath, $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME, $_.Exception.Message)
    }
    $token = ConvertFrom-SecureStringPlain -Secure $secure
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'Decrypted token is empty.' }
    Write-Log 'Token        : decrypted OK'

    $headers = @{
        'Authorization'        = ('token {0}' -f $token)
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'OfficeIT-RepoSync'
    }

    # --- Enumerate ----------------------------------------------------------
    $repos = Get-OrgRepository -Org $Organization -Headers $headers
    Write-Log ('API          : {0} repositories visible in {1}' -f @($repos).Count, $Organization)

    # --- Token expiry -------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($script:TokenExpiryRaw)) {
        Write-Log 'Token expiry : not reported (classic PAT, or no expiry set)'
    }
    else {
        # GitHub sends either "2027-09-11 00:00:00 +0200" or "... UTC".
        # .NET will not parse the literal UTC suffix, so normalise it first.
        $expiryRaw = ($script:TokenExpiryRaw -replace '\s+UTC\s*$', ' +0000').Trim()
        $expiry = [datetime]::MinValue
        if ([datetime]::TryParse($expiryRaw, [ref]$expiry)) {
            $daysLeft = [int]([math]::Floor(($expiry - (Get-Date)).TotalDays))
            if ($daysLeft -le 0) {
                Write-Log ('Token expiry : EXPIRED on {0}' -f $expiry.ToString('yyyy-MM-dd')) 'ERROR'
            }
            elseif ($daysLeft -le 30) {
                Write-Log ('Token expiry : {0} - only {1} day(s) left. Renew the PAT and re-run Set-OitcloudSyncToken.ps1.' -f $expiry.ToString('yyyy-MM-dd'), $daysLeft) 'WARN'
                $script:TokenExpiryWarning = ('Token expires {0} ({1} days)' -f $expiry.ToString('yyyy-MM-dd'), $daysLeft)
            }
            else {
                Write-Log ('Token expiry : {0} ({1} days left)' -f $expiry.ToString('yyyy-MM-dd'), $daysLeft)
            }
        }
        else {
            Write-Log ('Token expiry : could not parse header value "{0}"' -f $script:TokenExpiryRaw) 'WARN'
        }
    }

    $selected = @($repos)
    if (-not $IncludeArchived) {
        $archived = @($selected | Where-Object { $_.archived })
        if ($archived.Count -gt 0) {
            Write-Log ('Excluding {0} archived repositories: {1}' -f $archived.Count, (($archived | ForEach-Object { $_.name }) -join ', '))
        }
        $selected = @($selected | Where-Object { -not $_.archived })
    }
    if ($ExcludeRepo.Count -gt 0) {
        $selected = @($selected | Where-Object { $ExcludeRepo -notcontains $_.name })
        Write-Log ('Excluding by name: {0}' -f ($ExcludeRepo -join ', '))
    }
    $selected = @($selected | Sort-Object name)
    Write-Log ('In scope     : {0} repositories' -f $selected.Count)

    if ($selected.Count -eq 0) {
        throw 'No repositories in scope. Check the PAT scope and organization approval.'
    }

    # --- Prepare git auth ---------------------------------------------------
    if (-not (Test-Path -LiteralPath $RepoRoot)) {
        if ($PSCmdlet.ShouldProcess($RepoRoot, 'Create repo root directory')) {
            New-Item -Path $RepoRoot -ItemType Directory -Force | Out-Null
        }
    }

    $script:AskPassFile = New-AskPassShim -Directory $env:TEMP
    $env:OITSYNC_GH_TOKEN = $token
    $env:GIT_ASKPASS = $script:AskPassFile
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GCM_INTERACTIVE = 'never'

    # -c credential.helper= clears any configured helper (Git Credential Manager),
    # so the askpass shim is what answers, and nothing gets cached to the store.
    $authArgs = @('-c', 'credential.helper=', '-c', 'core.longpaths=true')

    # --- Per repository -----------------------------------------------------
    $i = 0
    foreach ($repo in $selected) {
        $i++
        $name = $repo.name
        $path = Join-Path $RepoRoot $name
        $url = 'https://x-access-token@github.com/{0}/{1}.git' -f $Organization, $name
        $status = 'UNKNOWN'
        $detail = ''

        Write-Log ('[{0}/{1}] {2}' -f $i, $selected.Count, $name)

        try {
            if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) {

                if (Test-Path -LiteralPath $path) {
                    $status = 'SKIP-NOTAREPO'
                    $detail = 'folder exists but is not a git working copy'
                    Write-Log ('    {0}: {1}' -f $status, $detail) 'WARN'
                }
                elseif ($PSCmdlet.ShouldProcess($name, 'git clone')) {
                    $r = Invoke-Git -WorkDir $RepoRoot -GitArgs ($authArgs + @('clone', '--quiet', $url, $name))
                    if ($r.ExitCode -eq 0) {
                        $status = 'CLONED'
                        $detail = $repo.default_branch
                        Write-Log ('    CLONED (default branch {0})' -f $repo.default_branch)
                    }
                    else {
                        $status = 'FAIL'
                        $detail = ($r.Output -replace '\s+', ' ')
                        Write-Log ('    FAIL clone: {0}' -f $detail) 'ERROR'
                    }
                }
                else {
                    $status = 'WHATIF-CLONE'
                    $detail = 'would clone'
                }
            }
            else {
                # Existing working copy.
                if ($PSCmdlet.ShouldProcess($name, 'git fetch --prune')) {
                    $f = Invoke-Git -WorkDir $path -GitArgs ($authArgs + @('fetch', '--prune', '--quiet', 'origin'))
                    if ($f.ExitCode -ne 0) {
                        $status = 'FAIL'
                        $detail = 'fetch: ' + ($f.Output -replace '\s+', ' ')
                        Write-Log ('    FAIL fetch: {0}' -f $detail) 'ERROR'
                        $results += [pscustomobject]@{ Name = $name; Status = $status; Detail = $detail }
                        continue
                    }
                }

                $dirty = Invoke-Git -WorkDir $path -GitArgs @('status', '--porcelain')
                $branch = (Invoke-Git -WorkDir $path -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')).Output

                if (-not [string]::IsNullOrWhiteSpace($dirty.Output)) {
                    $changed = @($dirty.Output -split "`r`n").Count
                    $status = 'SKIP-DIRTY'
                    $detail = ('{0} local change(s) on {1}; fetched only' -f $changed, $branch)
                    Write-Log ('    {0}: {1}' -f $status, $detail) 'WARN'
                }
                elseif ($branch -eq 'HEAD') {
                    $status = 'SKIP-DETACHED'
                    $detail = 'detached HEAD; fetched only'
                    Write-Log ('    {0}: {1}' -f $status, $detail) 'WARN'
                }
                else {
                    $up = Invoke-Git -WorkDir $path -GitArgs @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
                    if ($up.ExitCode -ne 0) {
                        $status = 'SKIP-NOUPSTREAM'
                        $detail = ('branch {0} has no upstream; fetched only' -f $branch)
                        Write-Log ('    {0}: {1}' -f $status, $detail) 'WARN'
                    }
                    else {
                        $counts = Invoke-Git -WorkDir $path -GitArgs @('rev-list', '--left-right', '--count', '@{u}...HEAD')
                        $parts = @($counts.Output -split '\s+')
                        $behind = 0
                        $ahead = 0
                        if ($parts.Count -ge 2) {
                            [void][int]::TryParse($parts[0], [ref]$behind)
                            [void][int]::TryParse($parts[1], [ref]$ahead)
                        }

                        if ($behind -gt 0 -and $ahead -gt 0) {
                            $status = 'SKIP-DIVERGED'
                            $detail = ('{0}: {1} ahead / {2} behind {3}; fetched only' -f $branch, $ahead, $behind, $up.Output)
                            Write-Log ('    {0}: {1}' -f $status, $detail) 'WARN'
                        }
                        elseif ($ahead -gt 0) {
                            $status = 'AHEAD'
                            $detail = ('{0}: {1} unpushed commit(s)' -f $branch, $ahead)
                            Write-Log ('    {0}: {1}' -f $status, $detail) 'WARN'
                        }
                        elseif ($behind -gt 0) {
                            if ($PSCmdlet.ShouldProcess($name, ('git merge --ff-only ({0} commits)' -f $behind))) {
                                $m = Invoke-Git -WorkDir $path -GitArgs @('merge', '--ff-only', '--quiet', '@{u}')
                                if ($m.ExitCode -eq 0) {
                                    $status = 'UPDATED'
                                    $detail = ('{0}: fast-forwarded {1} commit(s)' -f $branch, $behind)
                                    Write-Log ('    {0}: {1}' -f $status, $detail)
                                }
                                else {
                                    $status = 'FAIL'
                                    $detail = 'ff-only merge: ' + ($m.Output -replace '\s+', ' ')
                                    Write-Log ('    FAIL merge: {0}' -f $detail) 'ERROR'
                                }
                            }
                            else {
                                $status = 'WHATIF-FF'
                                $detail = ('would fast-forward {0} commit(s)' -f $behind)
                            }
                        }
                        else {
                            $status = 'CURRENT'
                            $detail = $branch
                            Write-Log ('    CURRENT ({0})' -f $branch)
                        }
                    }
                }
            }
        }
        catch {
            $status = 'FAIL'
            $detail = ($_.Exception.Message -replace '\s+', ' ')
            Write-Log ('    FAIL: {0}' -f $detail) 'ERROR'
        }

        $results += [pscustomobject]@{ Name = $name; Status = $status; Detail = $detail }
    }

    # --- Orphans (local folders no longer in the org) -----------------------
    $orgNames = @($repos | ForEach-Object { $_.name })
    if (Test-Path -LiteralPath $RepoRoot) {
        foreach ($dir in (Get-ChildItem -LiteralPath $RepoRoot -Directory -ErrorAction SilentlyContinue)) {
            if ($orgNames -notcontains $dir.Name -and (Test-Path -LiteralPath (Join-Path $dir.FullName '.git'))) {
                Write-Log ('ORPHAN: {0} is not (or no longer) in {1} - left untouched' -f $dir.Name, $Organization) 'WARN'
                $results += [pscustomobject]@{ Name = $dir.Name; Status = 'ORPHAN'; Detail = 'not in org; not deleted' }
            }
        }
    }
}
catch {
    $fatal = $true
    if ($script:LogFile) {
        Write-Log ('FATAL: {0}' -f $_.Exception.Message) 'ERROR'
    }
    else {
        Write-Output ('FATAL: {0}' -f $_.Exception.Message)
    }
}
finally {
    $env:OITSYNC_GH_TOKEN = $null
    $env:GIT_ASKPASS = $null
    $env:GIT_TERMINAL_PROMPT = $null
    $env:GCM_INTERACTIVE = $null
    if ($script:AskPassFile -and (Test-Path -LiteralPath $script:AskPassFile)) {
        Remove-Item -LiteralPath $script:AskPassFile -Force -ErrorAction SilentlyContinue
    }
    $token = $null
}

# ---------------------------------------------------------------------------
# Summary - built by hand. Format-Table | Out-String emits nothing with no console.
# ---------------------------------------------------------------------------

$fmt = '{0,-40} {1,-16} {2}'
$lines = @()
$lines += ''
$lines += '--- Summary ---'
$lines += ($fmt -f 'Repository', 'Status', 'Detail')
$lines += ($fmt -f ('-' * 40), ('-' * 16), ('-' * 40))
foreach ($row in ($results | Sort-Object Status, Name)) {
    $lines += ($fmt -f $row.Name, $row.Status, $row.Detail)
}

$counts = $results | Group-Object Status | Sort-Object Name
$lines += ''
foreach ($c in $counts) {
    $lines += ('{0,-16} {1}' -f $c.Name, $c.Count)
}

$failed = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$elapsed = (Get-Date) - $startedAt
$lines += ''
$lines += ('Elapsed: {0:N1} s   Failed: {1}   Total: {2}' -f $elapsed.TotalSeconds, $failed, $results.Count)
if ($script:TokenExpiryWarning) {
    $lines += ('WARNING: {0}' -f $script:TokenExpiryWarning)
}

$summary = $lines -join "`r`n"
Write-Output $summary
if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $summary -Encoding ASCII }

# --- Log rotation ----------------------------------------------------------
try {
    $old = Get-ChildItem -LiteralPath $LogDirectory -Filter 'sync-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip $KeepLogs
    if ($old) { $old | Remove-Item -Force -ErrorAction SilentlyContinue }
}
catch { }

if ($fatal) {
    Write-Output 'RESULT: FAIL (fatal error - see log)'
    exit 1
}
if ($failed -gt 0) {
    Write-Output ('RESULT: PARTIAL ({0} repository/repositories failed)' -f $failed)
    exit 2
}
Write-Output ('RESULT: PASS ({0} repositories processed, 0 failures)' -f $results.Count)
exit 0

<#
VERIFY
------
1) Run it by hand first, non-destructive dry run:

     .\Sync-OitcloudRepos.ps1 -WhatIf

   Expected: the repository list is enumerated and every line shows WHATIF-CLONE,
   WHATIF-FF, CURRENT or a SKIP-* status. Nothing is written to disk.

2) Real run:

     .\Sync-OitcloudRepos.ps1

   Expected last line: "RESULT: PASS (<n> repositories processed, 0 failures)"
   Anything starting with "RESULT: PARTIAL" or "RESULT: FAIL" means read the log.

3) Confirm the exit code the scheduled task will see:

     .\Sync-OitcloudRepos.ps1 | Out-Null
     Write-Output ("Exit code: {0} (expected 0)" -f $LASTEXITCODE)

4) Confirm no token leaked into any repo config:

     $hits = Get-ChildItem C:\GITWork -Recurse -Depth 2 -Filter config -File -Force |
         Select-String -Pattern 'ghp_|github_pat_|x-access-token:' -List
     if ($hits) { Write-Output "FAIL: token material found in:"; $hits.Path }
     else { Write-Output "PASS: no token material in any .git/config" }

   Expected: "PASS: no token material in any .git/config"
#>
