<#
.SYNOPSIS
    Registers the OITCLOUD repo sync as a Windows scheduled task.

.DESCRIPTION
    Creates (or replaces) a scheduled task that runs Sync-OitcloudRepos.ps1 as the
    current user, whether or not that user is logged on.

    LogonType is Password on purpose. "Run whether user is logged on or not" with
    S4U (no password stored) does NOT load the user profile's DPAPI master key, so
    the encrypted token file would fail to decrypt. Storing the password is what
    makes DPAPI work here.

    The account also needs the "Log on as a batch job" right. On a domain-joined or
    standard machine it usually has it; if task registration fails with 0x80070534
    or the task ends with 0x41303 / "The user account does not have permission",
    grant it in secpol.msc -> Local Policies -> User Rights Assignment.

.PARAMETER ScriptPath
    Full path to Sync-OitcloudRepos.ps1. Defaults to the copy next to this script.

.PARAMETER RepoRoot
    Passed through to the sync script. Default: C:\GITWork

.PARAMETER TaskName
    Default: Office-IT\Sync-OITCLOUD-Repos

.PARAMETER At
    Daily start time, 24h. Default: 07:30

.PARAMETER RepeatEveryHours
    0 = once a day. Any value from 1 to 12 creates one daily trigger per slot through
    the day (4 -> 6 triggers). Fixed daily times are used rather than a repetition
    interval: [TimeSpan]::MaxValue as a repetition duration serialises to
    P99999999DT23H59M59S, which Task Scheduler rejects with "The task XML contains a
    value which is incorrectly formatted or out of range".

.PARAMETER Remove
    Unregister the task instead of creating it.

.EXAMPLE
    .\Register-OitcloudSyncTask.ps1 -At 07:30 -RepeatEveryHours 4

.EXAMPLE
    .\Register-OitcloudSyncTask.ps1 -Remove

.NOTES
    Author       : Office-IT
    Requires     : Windows PowerShell 5.1, run elevated
    Encoding     : ASCII (no BOM)
    Verification : see the VERIFY block at the end of this file
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'Sync-OitcloudRepos.ps1'),
    [string]$RepoRoot = 'C:\GITWork',
    [string]$TaskName = 'Sync-OITCLOUD-Repos',
    [string]$TaskPath = '\Office-IT\',
    [datetime]$At = (Get-Date -Hour 7 -Minute 30 -Second 0),
    [ValidateRange(0, 12)][int]$RepeatEveryHours = 0,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

try {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw 'Run this script from an elevated PowerShell session (Run as administrator).'
    }

    if ($Remove) {
        $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
        if (-not $existing) {
            Write-Output ('Nothing to do: task {0}{1} does not exist.' -f $TaskPath, $TaskName)
            exit 0
        }
        if ($PSCmdlet.ShouldProcess(($TaskPath + $TaskName), 'Unregister scheduled task')) {
            Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
            $gone = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
            if ($gone) { throw 'Unregister reported success but the task is still present.' }
            Write-Output ('PASS: task {0}{1} removed.' -f $TaskPath, $TaskName)
        }
        exit 0
    }

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw ('Sync script not found: {0}' -f $ScriptPath)
    }

    $user = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME

    Write-Output ''
    Write-Output '=== Register OITCLOUD repo sync task ==='
    Write-Output ('Task      : {0}{1}' -f $TaskPath, $TaskName)
    Write-Output ('Script    : {0}' -f $ScriptPath)
    Write-Output ('Repo root : {0}' -f $RepoRoot)
    Write-Output ('Run as    : {0}' -f $user)
    Write-Output ('Schedule  : daily at {0}{1}' -f $At.ToString('HH:mm'), $(if ($RepeatEveryHours -gt 0) { ", repeating every $RepeatEveryHours h" } else { '' }))
    Write-Output ''
    Write-Output 'The token file is DPAPI-encrypted for this account, so the task must run'
    Write-Output 'as this same account with its password stored. You will be asked for it now.'
    Write-Output ''

    $cred = Get-Credential -UserName $user -Message ('Windows password for {0} (stored by Task Scheduler)' -f $user)
    if ($null -eq $cred) { throw 'No credentials supplied.' }
    if ($cred.UserName -ne $user) {
        Write-Output ('NOTE: running the task as {0} instead of {1}. The token file must have been created by that account.' -f $cred.UserName, $user)
    }

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
    try {
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RepoRoot "{1}"' -f $ScriptPath, $RepoRoot
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments -WorkingDirectory (Split-Path -Path $ScriptPath -Parent)

    # Repetition is expressed as several daily triggers rather than a single -Once
    # trigger with -RepetitionInterval/-RepetitionDuration. [TimeSpan]::MaxValue
    # serialises to P99999999DT23H59M59S, which Task Scheduler rejects with
    # "The task XML contains a value which is incorrectly formatted or out of range",
    # and the alternatives are inconsistent across Windows builds. Fixed daily times
    # are unambiguous, survive reboots, and are readable in the Task Scheduler UI.
    $trigger = @()
    if ($RepeatEveryHours -gt 0) {
        $times = @()
        for ($h = 0; $h -lt 24; $h += $RepeatEveryHours) {
            $t = $At.AddHours($h)
            $times += $t
            $trigger += New-ScheduledTaskTrigger -Daily -At $t
        }
        Write-Output ('Triggers  : {0} daily, at {1}' -f $times.Count, (($times | ForEach-Object { $_.ToString('HH:mm') }) -join ', '))
        if (24 % $RepeatEveryHours -ne 0) {
            Write-Output ('            NOTE: {0} does not divide 24 evenly, so the gap across midnight is longer than {0}h.' -f $RepeatEveryHours)
        }
    }
    else {
        $trigger += New-ScheduledTaskTrigger -Daily -At $At
        Write-Output ('Triggers  : 1 daily, at {0}' -f $At.ToString('HH:mm'))
    }

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
        -RunOnlyIfNetworkAvailable

    if ($PSCmdlet.ShouldProcess(($TaskPath + $TaskName), 'Register scheduled task')) {
        $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Output 'Existing task found - it will be replaced in place.'
        }

        # -Force replaces an existing task. Deliberately NOT unregistering first:
        # if registration then failed, the working task would already be gone.
        try {
            Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Force `
                -Action $action -Trigger $trigger -Settings $settings `
                -User $cred.UserName -Password $plainPassword -RunLevel Limited `
                -Description 'Clones and fast-forwards all non-archived OITCLOUD GitHub repositories. Skips repositories with local changes.' | Out-Null
        }
        catch {
            $msg = $_.Exception.Message
            if ($msg -match 'incorrectly formatted or out of range') {
                throw ('Task Scheduler rejected the task XML: {0}. This is a trigger definition problem, not a credential problem.' -f $msg)
            }
            if ($msg -match '0x80070534|no mapping between account names') {
                throw ('Windows could not resolve the account {0}. Use DOMAIN\user or .\user exactly as it appears in whoami.' -f $cred.UserName)
            }
            if ($msg -match 'logon failure|0x8007052E|incorrect password') {
                throw ('The password for {0} was rejected by Windows.' -f $cred.UserName)
            }
            throw ('Register-ScheduledTask failed: {0}' -f $msg)
        }
        finally {
            $plainPassword = $null
        }

        # --- Verify -------------------------------------------------------
        $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
        if (-not $task) {
            throw ('Register-ScheduledTask reported success but no task exists at {0}{1}.' -f $TaskPath, $TaskName)
        }
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop

        Write-Output ''
        Write-Output ('PASS: task registered  : {0}{1}' -f $TaskPath, $TaskName)
        Write-Output ('      State            : {0}   (expected: Ready)' -f $task.State)
        Write-Output ('      Principal        : {0} / LogonType {1}   (expected LogonType: Password)' -f $task.Principal.UserId, $task.Principal.LogonType)
        Write-Output ('      Triggers         : {0}' -f @($task.Triggers).Count)
        Write-Output ('      Next run         : {0}' -f $info.NextRunTime)
        Write-Output ('      Command          : powershell.exe {0}' -f $arguments)
        Write-Output ''
        Write-Output 'Now run it once on demand to prove it works end to end:'
        Write-Output ('  Start-ScheduledTask -TaskName "{0}" -TaskPath "{1}"' -f $TaskName, $TaskPath)
        Write-Output ('  Start-Sleep -Seconds 60')
        Write-Output ('  (Get-ScheduledTaskInfo -TaskName "{0}" -TaskPath "{1}").LastTaskResult   # expected: 0' -f $TaskName, $TaskPath)
    }

    exit 0
}
catch {
    Write-Output ''
    Write-Output ('FAIL: {0}' -f $_.Exception.Message)
    exit 1
}

<#
VERIFY
------
1) Task exists and is Ready:

     Get-ScheduledTask -TaskName 'Sync-OITCLOUD-Repos' -TaskPath '\Office-IT\' |
         Select-Object TaskName, State, @{n='User';e={$_.Principal.UserId}}, @{n='Logon';e={$_.Principal.LogonType}}

   Expected: State = Ready, Logon = Password.

2) On-demand run returns exit code 0:

     Start-ScheduledTask -TaskName 'Sync-OITCLOUD-Repos' -TaskPath '\Office-IT\'
     Start-Sleep -Seconds 90
     $i = Get-ScheduledTaskInfo -TaskName 'Sync-OITCLOUD-Repos' -TaskPath '\Office-IT\'
     Write-Output ("LastTaskResult: {0} (expected 0), LastRunTime: {1}" -f $i.LastTaskResult, $i.LastRunTime)

   Expected: LastTaskResult 0. A 2 means some repositories failed, 1 means fatal,
   0x41303 means the task never ran (batch logon right), 0x1 usually means the
   script itself threw before writing a log.

3) The run produced a log with a PASS line:

     $log = Get-ChildItem "$env:LOCALAPPDATA\Office-IT\GitHubSync\logs\sync-*.log" |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
     Write-Output ("Log: {0}" -f $log.FullName)
     Get-Content $log.FullName -Tail 12

   Expected: the summary table and a final line "RESULT: PASS (... 0 failures)".
#>
