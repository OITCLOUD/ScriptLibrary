<#
.SYNOPSIS
    One-time setup: stores a GitHub PAT for the OITCLOUD repo sync, DPAPI-encrypted.

.DESCRIPTION
    Prompts for a GitHub Personal Access Token, validates it live against the GitHub
    API (identity + OITCLOUD org visibility), then writes it to an encrypted file.

    Encryption is Windows DPAPI via ConvertFrom-SecureString. The resulting file can
    ONLY be decrypted by the same Windows user account on the same machine. Run this
    script logged on as the account the scheduled task will run as.

    The file is written -Encoding ASCII -NoNewline and is read back and proven to
    decrypt before success is reported.

.PARAMETER TokenPath
    Where the encrypted token is stored. Default:
    %LOCALAPPDATA%\Office-IT\GitHubSync\oitcloud-token.sec

.PARAMETER Organization
    GitHub organization to validate against. Default: OITCLOUD

.EXAMPLE
    .\Set-OitcloudSyncToken.ps1

.NOTES
    Author       : Office-IT
    Requires     : Windows PowerShell 5.1
    Encoding     : ASCII (no BOM)
    Verification : script reads the file back and decrypts it before reporting success
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$TokenPath = (Join-Path $env:LOCALAPPDATA 'Office-IT\GitHubSync\oitcloud-token.sec'),
    [string]$Organization = 'OITCLOUD'
)

$ErrorActionPreference = 'Stop'

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

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Output ''
    Write-Output '=== OITCLOUD GitHub sync - token setup ==='
    Write-Output ("Account  : {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
    Write-Output ("Machine  : {0}" -f $env:COMPUTERNAME)
    Write-Output ("Target   : {0}" -f $TokenPath)
    Write-Output ''
    Write-Output 'The token is encrypted with Windows DPAPI and is only readable by the'
    Write-Output 'account and machine shown above. Required PAT scope: repo (read is enough).'
    Write-Output ''

    $secure = Read-Host -Prompt 'Paste the GitHub PAT' -AsSecureString
    $plain = ConvertFrom-SecureStringPlain -Secure $secure

    if ([string]::IsNullOrWhiteSpace($plain)) {
        throw 'No token entered.'
    }

    # --- Live validation before anything is written -------------------------
    $headers = @{
        'Authorization'        = ('token {0}' -f $plain)
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'OfficeIT-RepoSync'
    }

    Write-Output 'Validating token against api.github.com ...'
    $me = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers -Method Get -ErrorAction Stop
    Write-Output ("  Authenticated as : {0}" -f $me.login)

    $org = Invoke-RestMethod -Uri ('https://api.github.com/orgs/{0}' -f $Organization) -Headers $headers -Method Get -ErrorAction Stop
    Write-Output ("  Organization     : {0} (id {1})" -f $org.login, $org.id)

    $probe = Invoke-WebRequest -Uri ('https://api.github.com/orgs/{0}/repos?per_page=1&type=all' -f $Organization) `
        -Headers $headers -Method Get -UseBasicParsing -ErrorAction Stop
    $probeRepos = $probe.Content | ConvertFrom-Json
    if ($null -eq $probeRepos -or @($probeRepos).Count -eq 0) {
        Write-Output '  WARNING: the token authenticates but sees 0 repositories in the org.'
        Write-Output '           Check the PAT scope (classic: repo / read:org) or, for a'
        Write-Output '           fine-grained PAT, that OITCLOUD approved it and granted'
        Write-Output '           Contents: Read-only + Metadata: Read-only on all repositories.'
    }
    else {
        Write-Output ("  Repo visibility  : OK (sample: {0})" -f @($probeRepos)[0].name)
    }

    # --- Write ---------------------------------------------------------------
    $dir = Split-Path -Path $TokenPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        if ($PSCmdlet.ShouldProcess($dir, 'Create directory')) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }
    }

    if (Test-Path -LiteralPath $TokenPath) {
        $backup = ('{0}.{1}.bak' -f $TokenPath, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        if ($PSCmdlet.ShouldProcess($TokenPath, ('Back up existing token file to {0}' -f $backup))) {
            Copy-Item -LiteralPath $TokenPath -Destination $backup -Force
            Write-Output ("Existing token file backed up to: {0}" -f $backup)
        }
    }

    if ($PSCmdlet.ShouldProcess($TokenPath, 'Write DPAPI-encrypted token file')) {
        $encrypted = $secure | ConvertFrom-SecureString
        Set-Content -Path $TokenPath -Value $encrypted -Encoding ASCII -NoNewline

        # Lock the file down to this account only.
        $acl = Get-Acl -LiteralPath $TokenPath
        $acl.SetAccessRuleProtection($true, $false)
        $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME), 'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $TokenPath -AclObject $acl

        # --- Verify: read back and prove it decrypts -------------------------
        $check = Read-DataFile -Path $TokenPath | ConvertTo-SecureString -ErrorAction Stop
        $checkPlain = ConvertFrom-SecureStringPlain -Secure $check
        if ($checkPlain -ne $plain) {
            throw ('Token file at {0} was written but round-trips to a different value.' -f $TokenPath)
        }

        Write-Output ''
        Write-Output ("PASS: token file verified OK: {0}" -f $TokenPath)
        Write-Output ("PASS: decrypts to the same value under {0}\{1} on {2}" -f $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME)
    }

    $plain = $null
    $checkPlain = $null

    exit 0
}
catch {
    Write-Output ''
    Write-Output ("FAIL: {0}" -f $_.Exception.Message)
    exit 1
}
