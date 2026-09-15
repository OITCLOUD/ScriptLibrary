<#
.SYNOPSIS
    Diagnoses why some OITCLOUD repositories fail to sync. Read-only, changes nothing.

.DESCRIPTION
    For every repository the token can enumerate, this reports:
      - what the GitHub API says the token may do (pull / push / admin)
      - whether an actual authenticated git read succeeds (git ls-remote, no clone)
      - the first line of the real git error when it does not
      - whether the local folder is writable, for repos already on disk

    It then maps the observed errors onto the known causes.

    Nothing is cloned, fetched, merged or written except a temporary askpass shim in
    %TEMP%, which is removed at the end.

.PARAMETER RepoRoot
    Same value used with Sync-OitcloudRepos.ps1. Default: C:\GITWork

.PARAMETER TokenPath
    DPAPI-encrypted token file written by Set-OitcloudSyncToken.ps1.

.PARAMETER Organization
    Default: OITCLOUD

.EXAMPLE
    .\Test-OitcloudSyncAccess.ps1

.NOTES
    Author       : Office-IT
    Requires     : Windows PowerShell 5.1, git for Windows on PATH
    Encoding     : ASCII (no BOM)
    Verification : the script IS the verification - every line prints a result
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = 'C:\GITWork',
    [string]$TokenPath = (Join-Path $env:LOCALAPPDATA 'Office-IT\GitHubSync\oitcloud-token.sec'),
    [string]$Organization = 'OITCLOUD'
)

$ErrorActionPreference = 'Stop'
$askPassFile = $null

function Read-DataFile {
    param([Parameter(Mandatory)][string]$Path)
    $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
    if ($null -eq $raw) { return $null }
    $bom = [char]0xFEFF
    while ($raw.Length -gt 0 -and $raw[0] -eq $bom) { $raw = $raw.Substring(1) }
    return $raw.Trim()
}

function ConvertFrom-SecureStringPlain {
    param([Parameter(Mandatory)][System.Security.SecureString]$Secure)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Invoke-Git {
    param([string]$WorkDir, [Parameter(Mandatory)][string[]]$GitArgs)
    $ErrorActionPreference = 'Continue'
    $prev = (Get-Location).Path
    try {
        if ($WorkDir) { Set-Location -LiteralPath $WorkDir }
        $raw = & git @GitArgs 2>&1
        $code = $LASTEXITCODE
        $text = (@($raw) | ForEach-Object { $_.ToString() }) -join "`r`n"
        return [pscustomobject]@{ ExitCode = $code; Output = $text.Trim() }
    }
    finally { Set-Location -LiteralPath $prev }
}

function Test-FolderWritable {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $probe = Join-Path $Path ('.oitsync-write-probe-{0}' -f $PID)
        Set-Content -Path $probe -Value 'probe' -Encoding ASCII -NoNewline -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return 'yes'
    }
    catch { return 'NO' }
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Output ''
    Write-Output '=== OITCLOUD sync access diagnostic ==='
    Write-Output ('Account   : {0}\{1} on {2}' -f $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME)
    Write-Output ('Repo root : {0}' -f $RepoRoot)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git not found on PATH.' }
    Write-Output ('Git       : {0}' -f (Invoke-Git -GitArgs @('--version')).Output)

    # --- Token --------------------------------------------------------------
    $token = ConvertFrom-SecureStringPlain -Secure ((Read-DataFile -Path $TokenPath) | ConvertTo-SecureString)
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'Decrypted token is empty.' }

    $kind = 'unknown'
    if ($token.StartsWith('github_pat_')) { $kind = 'fine-grained PAT' }
    elseif ($token.StartsWith('ghp_')) { $kind = 'classic PAT' }
    elseif ($token.StartsWith('gho_') -or $token.StartsWith('ghu_')) { $kind = 'OAuth/user-to-server token' }
    elseif ($token.StartsWith('ghs_')) { $kind = 'GitHub App installation token' }
    Write-Output ('Token type: {0} (prefix only - the value is never printed)' -f $kind)

    $headers = @{
        'Authorization'        = ('token {0}' -f $token)
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'OfficeIT-RepoSync'
    }

    $userResp = Invoke-WebRequest -Uri 'https://api.github.com/user' -Headers $headers -UseBasicParsing
    $me = $userResp.Content | ConvertFrom-Json
    Write-Output ('Login     : {0}' -f $me.login)

    $scopes = $userResp.Headers['X-OAuth-Scopes']
    if ($scopes) {
        Write-Output ('Scopes    : {0}' -f $scopes)
        if ($scopes -notmatch '(^|,\s*)repo(,|$)') {
            Write-Output '            WARNING: classic PAT without the full "repo" scope cannot read private repositories.'
        }
    }
    else {
        Write-Output 'Scopes    : none reported - this is normal for a fine-grained PAT (permissions are per repository)'
    }

    # --- Enumerate ----------------------------------------------------------
    $repos = @()
    $uri = 'https://api.github.com/orgs/{0}/repos?per_page=100&type=all&sort=full_name' -f $Organization
    while ($uri) {
        $resp = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing
        $repos += @($resp.Content | ConvertFrom-Json)
        $uri = $null
        $link = $resp.Headers['Link']
        if ($link) {
            foreach ($part in ($link -split ',')) {
                if ($part -match '<([^>]+)>;\s*rel="next"') { $uri = $Matches[1]; break }
            }
        }
    }
    Write-Output ('Repos     : {0} enumerated in {1}' -f $repos.Count, $Organization)

    # --- Local root ---------------------------------------------------------
    if (Test-Path -LiteralPath $RepoRoot) {
        Write-Output ('Root write: {0}' -f (Test-FolderWritable -Path $RepoRoot))
        if ($RepoRoot -like '*OneDrive*' -or $RepoRoot -like '*SharePoint*') {
            Write-Output '            WARNING: repo root sits inside a sync client folder. Git and file sync fight over .git - move it out.'
        }
    }
    else {
        Write-Output ('Root write: root does not exist yet ({0})' -f $RepoRoot)
    }

    # --- Askpass shim -------------------------------------------------------
    $askPassFile = Join-Path $env:TEMP ('oitdiag-askpass-{0}.cmd' -f $PID)
    $lines = @(
        '@echo off',
        'echo.%~1| findstr /i "Username" >nul',
        'if %errorlevel%==0 (',
        '  echo x-access-token',
        ') else (',
        '  echo %OITSYNC_GH_TOKEN%',
        ')'
    )
    Set-Content -Path $askPassFile -Value ($lines -join "`r`n") -Encoding ASCII

    $env:OITSYNC_GH_TOKEN = $token
    $env:GIT_ASKPASS = $askPassFile
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GCM_INTERACTIVE = 'never'
    $authArgs = @('-c', 'credential.helper=')

    # --- Per repository -----------------------------------------------------
    $rows = @()
    $i = 0
    foreach ($repo in ($repos | Sort-Object name)) {
        $i++
        Write-Progress -Activity 'Probing repositories' -Status $repo.name -PercentComplete (($i / [Math]::Max($repos.Count, 1)) * 100)

        $url = 'https://x-access-token@github.com/{0}/{1}.git' -f $Organization, $repo.name
        $probe = Invoke-Git -GitArgs ($authArgs + @('ls-remote', '--heads', '--quiet', $url))

        $err = ''
        if ($probe.ExitCode -ne 0) {
            $firstErr = @($probe.Output -split "`r`n" | Where-Object { $_ -match '\S' }) |
                Where-Object { $_ -match 'remote:|fatal:|error:' } | Select-Object -First 1
            if (-not $firstErr) { $firstErr = ($probe.Output -split "`r`n")[0] }
            $err = ($firstErr -replace '\s+', ' ')
            if ($err.Length -gt 90) { $err = $err.Substring(0, 90) }
        }

        $local = 'absent'
        $localPath = Join-Path $RepoRoot $repo.name
        if (Test-Path -LiteralPath (Join-Path $localPath '.git')) {
            $local = Test-FolderWritable -Path $localPath
            if ($local -eq 'yes') { $local = 'rw' }
        }
        elseif (Test-Path -LiteralPath $localPath) { $local = 'notrepo' }

        $rows += [pscustomobject]@{
            Name     = $repo.name
            Private  = $(if ($repo.private) { 'priv' } else { 'pub' })
            Archived = $(if ($repo.archived) { 'arch' } else { '' })
            Pull     = $(if ($repo.permissions -and $repo.permissions.pull) { 'Y' } else { 'n' })
            Push     = $(if ($repo.permissions -and $repo.permissions.push) { 'Y' } else { 'n' })
            Read     = $(if ($probe.ExitCode -eq 0) { 'OK' } else { 'FAIL' })
            Local    = $local
            Error    = $err
        }
    }
    Write-Progress -Activity 'Probing repositories' -Completed
}
catch {
    Write-Output ''
    Write-Output ('FAIL: {0}' -f $_.Exception.Message)
    exit 1
}
finally {
    $env:OITSYNC_GH_TOKEN = $null
    $env:GIT_ASKPASS = $null
    $env:GIT_TERMINAL_PROMPT = $null
    $env:GCM_INTERACTIVE = $null
    if ($askPassFile -and (Test-Path -LiteralPath $askPassFile)) {
        Remove-Item -LiteralPath $askPassFile -Force -ErrorAction SilentlyContinue
    }
    $token = $null
}

# --- Report (hand-built: Format-Table | Out-String emits nothing unattended) --
$fmt = '{0,-34} {1,-5} {2,-5} {3,-5} {4,-5} {5,-5} {6,-8} {7}'
$out = @()
$out += ''
$out += ($fmt -f 'Repository', 'Vis', 'Arch', 'Pull', 'Push', 'Read', 'Local', 'First error')
$out += ($fmt -f ('-' * 34), ('-' * 5), ('-' * 5), ('-' * 5), ('-' * 5), ('-' * 5), ('-' * 8), ('-' * 40))
foreach ($r in ($rows | Sort-Object Read, Name)) {
    $out += ($fmt -f $r.Name, $r.Private, $r.Archived, $r.Pull, $r.Push, $r.Read, $r.Local, $r.Error)
}

$fail = @($rows | Where-Object { $_.Read -eq 'FAIL' })
$out += ''
$out += ('Readable: {0} of {1}   Failing: {2}' -f ($rows.Count - $fail.Count), $rows.Count, $fail.Count)
Write-Output ($out -join "`r`n")

if ($fail.Count -gt 0) {
    Write-Output ''
    Write-Output '--- Diagnosis ---'
    $seen = @{}
    foreach ($f in $fail) {
        $cause = 'Unrecognised error - paste this line and I will work it out.'
        switch -Regex ($f.Error) {
            'Write access to repository not granted' {
                $cause = 'GitHub 403 on a READ. The message is misleading - it means the token has no Contents permission on THIS repo. Fine-grained PAT: set Repository access to "All repositories" and Contents: Read-only, then have an org owner approve it. Classic PAT: needs the full "repo" scope.'
            }
            'Repository not found|not found' {
                $cause = 'Token cannot see the repo at all: not granted, or the classic PAT is not SSO-authorized for OITCLOUD.'
            }
            'SAML|SSO|single sign-on' {
                $cause = 'Classic PAT must be SSO-authorized: GitHub > Settings > Developer settings > Tokens > Configure SSO > Authorize for OITCLOUD.'
            }
            'could not read Username|terminal prompts disabled|Authentication failed' {
                $cause = 'The askpass shim did not supply credentials. Check that %TEMP% allows .cmd execution and that no AppLocker/SRP rule blocks it.'
            }
            'rate limit' {
                $cause = 'API or git rate limit hit. Re-run later or reduce the repetition interval.'
            }
        }
        if (-not $seen.ContainsKey($cause)) {
            $seen[$cause] = @()
        }
        $seen[$cause] += $f.Name
    }
    foreach ($k in $seen.Keys) {
        Write-Output ''
        Write-Output ('* {0}' -f $k)
        Write-Output ('  Affects ({0}): {1}' -f $seen[$k].Count, (($seen[$k]) -join ', '))
    }
    Write-Output ''
    Write-Output ('RESULT: {0} repositories are NOT readable with this token.' -f $fail.Count)
    exit 2
}

Write-Output ''
Write-Output 'RESULT: PASS - every enumerated repository is readable with this token.'
Write-Output 'If the sync still fails, the problem is local (folder permissions, locked files), not the token.'
exit 0
