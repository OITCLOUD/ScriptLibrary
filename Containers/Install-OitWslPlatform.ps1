<#
.SYNOPSIS
    Phase 1 of the Office-IT container workstation rollout: enables the Windows features for
    WSL2 and installs/updates the WSL package. Machine-wide, needs admin.

.DESCRIPTION
    - Checks Windows build, 64-bit process and virtualisation
    - Enables Microsoft-Windows-Subsystem-Linux and VirtualMachinePlatform (no automatic reboot)
    - Installs or updates WSL from the web package (wsl.exe --update --web-download)
    Idempotent: safe to run again. Does not install a Linux distro; that is phase 2
    (Install-OitWslDocker.ps1, run as the logged-on user), because WSL distros are per user.

    NinjaOne: script library, language PowerShell, Run As: System.
    Manual: save as Install-OitWslPlatform.ps1 and run in an elevated Windows PowerShell:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-OitWslPlatform.ps1

.NOTES
    Script  : Install-OitWslPlatform.ps1
    Version : 0.2.0
    Date    : 2026-10-18
    Target  : Windows PowerShell 5.1, 64-bit
    Run as  : SYSTEM or local administrator
    Exit    : 0 = RESULT: OK, 3010 = RESULT: REBOOT REQUIRED (run again after reboot), 1 = RESULT: FAILED
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ScriptVersion = '0.2.0'
$env:WSL_UTF8 = '1'

function Write-Step {
    param([string]$Status, [string]$Message)
    Write-Output ("{0} {1}" -f $Status.PadRight(4), $Message)
}

function Stop-Script {
    param([string]$Message)
    Write-Step 'FAIL' $Message
    Write-Output ("RESULT: FAILED - {0}" -f $Message)
    exit 1
}

function Invoke-Native {
    # Local Continue: native stderr with 2>&1 under Stop is terminating in Windows PowerShell 5.1.
    param([string]$FilePath, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $out = & $FilePath @Arguments 2>&1
    $code = $LASTEXITCODE
    $text = (($out | ForEach-Object { "$_" }) -join "`n") -replace "`0", ''
    return [pscustomobject]@{ ExitCode = $code; Text = $text.Trim() }
}

Write-Output ("Install-OitWslPlatform v{0}  {1}  {2}" -f $ScriptVersion, $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm'))

# 1. Pre-checks
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Stop-Script 'not running as administrator or SYSTEM'
}
Write-Step 'PASS' 'running elevated'

if (-not [Environment]::Is64BitProcess) {
    Stop-Script '32-bit PowerShell; run with 64-bit PowerShell (C:\Windows\Sysnative\WindowsPowerShell\v1.0\powershell.exe)'
}
Write-Step 'PASS' '64-bit process'

$os = Get-CimInstance -ClassName Win32_OperatingSystem
if ([int]$os.BuildNumber -lt 19045) {
    Stop-Script ("Windows build {0}; need Windows 10 22H2 (19045) or Windows 11" -f $os.BuildNumber)
}
Write-Step 'PASS' ("{0} build {1}" -f $os.Caption, $os.BuildNumber)

$cs = Get-CimInstance -ClassName Win32_ComputerSystem
$cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
if (-not ($cs.HypervisorPresent -or $cpu.VirtualizationFirmwareEnabled)) {
    Stop-Script 'virtualisation disabled in BIOS/UEFI; enable it first'
}
Write-Step 'PASS' 'virtualisation available'

# 2. Windows optional features
$rebootNeeded = $false
foreach ($feature in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature).State
    if ("$state" -eq 'Enabled') {
        Write-Step 'PASS' ("feature {0} already enabled" -f $feature)
        continue
    }
    $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
    if ($result.RestartNeeded) { $rebootNeeded = $true }
    $after = (Get-WindowsOptionalFeature -Online -FeatureName $feature).State
    if ("$after" -eq 'Enabled' -or "$after" -eq 'EnablePending') {
        Write-Step 'PASS' ("feature {0} -> {1}" -f $feature, $after)
        if ("$after" -eq 'EnablePending') { $rebootNeeded = $true }
    }
    else {
        Stop-Script ("feature {0} could not be enabled (state {1})" -f $feature, $after)
    }
}

if ($rebootNeeded) {
    Write-Step 'INFO' 'features enabled; WSL package is installed after the reboot'
    Write-Output 'RESULT: REBOOT REQUIRED - reboot, then run this script again'
    exit 3010
}

# 3. WSL package (Store/web version). 'wsl --version' only succeeds on the modern package.
$wslExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\wsl.exe'
if (-not (Test-Path -Path $wslExe)) {
    Stop-Script 'wsl.exe not found after enabling features'
}

$ver = Invoke-Native -FilePath $wslExe -Arguments @('--version')
if ($ver.ExitCode -ne 0) {
    Write-Step 'INFO' 'modern WSL package not present, installing from web package'
    $upd = Invoke-Native -FilePath $wslExe -Arguments @('--update', '--web-download')
    Write-Step 'INFO' ("wsl --update exit {0}" -f $upd.ExitCode)
    $ver = Invoke-Native -FilePath $wslExe -Arguments @('--version')
}
if ($ver.ExitCode -ne 0) {
    Stop-Script ("WSL package not available after update. Output: {0}" -f $ver.Text)
}
$firstLine = ($ver.Text -split "`n" | Select-Object -First 1).Trim()
Write-Step 'PASS' ("WSL package: {0}" -f $firstLine)

$def = Invoke-Native -FilePath $wslExe -Arguments @('--set-default-version', '2')
if ($def.ExitCode -eq 0) {
    Write-Step 'PASS' 'default WSL version set to 2'
}
else {
    Write-Step 'INFO' ("could not set default version 2 (exit {0}); phase 2 imports with --version 2 anyway" -f $def.ExitCode)
}

Write-Output 'RESULT: OK - WSL platform ready; run Install-OitWslDocker.ps1 as the logged-on user'
exit 0
