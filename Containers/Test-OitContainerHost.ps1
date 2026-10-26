<#
.SYNOPSIS
    Read-only readiness check for running Office-IT tool containers on a Windows workstation.

.DESCRIPTION
    Checks Windows build, virtualisation, WSL2, the Ubuntu distro, systemd and Docker Engine
    inside WSL. Changes nothing. Ends with RESULT: READY or RESULT: NOT READY.

    Save as Test-OitContainerHost.ps1 and run with:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-OitContainerHost.ps1

.NOTES
    Script  : Test-OitContainerHost.ps1
    Version : 0.2.2
    Date    : 2026-10-18
    Target  : Windows PowerShell 5.1 (also runs on PowerShell 7)
    Admin   : not required
    Exit    : 0 = READY, 1 = NOT READY
#>
[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu-26.04'
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '0.2.2'

# wsl.exe writes UTF-16 by default; ask it for UTF-8 in this session.
$env:WSL_UTF8 = '1'

$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string]$Check,
        [ValidateSet('PASS', 'FAIL', 'INFO')][string]$Status,
        [string]$Detail
    )
    $results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
}

function Invoke-Wsl {
    # Runs wsl.exe and returns cleaned text. Strips NUL characters in case UTF-8 mode is not honoured.
    # Local Continue: in Windows PowerShell 5.1, native stderr redirected with 2>&1 under
    # ErrorActionPreference Stop becomes a terminating error.
    param([string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $out = & wsl.exe @Arguments 2>&1
    $code = $LASTEXITCODE
    $text = (($out | ForEach-Object { "$_" }) -join "`n") -replace "`0", ''
    return [pscustomobject]@{ ExitCode = $code; Text = $text.Trim() }
}

# 1. Windows build
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    if ($build -ge 19045) {
        Add-Result 'Windows build' 'PASS' ("{0} build {1}" -f $os.Caption, $build)
    }
    else {
        Add-Result 'Windows build' 'FAIL' ("build {0}; need Windows 10 22H2 (19045) or Windows 11" -f $build)
    }
}
catch {
    Add-Result 'Windows build' 'FAIL' $_.Exception.Message
}

# 2. Virtualisation. VirtualizationFirmwareEnabled reads False once a hypervisor is running,
#    so a running hypervisor also counts as a pass.
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    if ($cs.HypervisorPresent) {
        Add-Result 'Virtualisation' 'PASS' 'hypervisor is running'
    }
    elseif ($cpu.VirtualizationFirmwareEnabled) {
        Add-Result 'Virtualisation' 'PASS' 'enabled in firmware'
    }
    else {
        Add-Result 'Virtualisation' 'FAIL' 'disabled in BIOS/UEFI - raise a ticket'
    }
}
catch {
    Add-Result 'Virtualisation' 'FAIL' $_.Exception.Message
}

# 3. Disk space on the system drive
try {
    $sysDrive = $env:SystemDrive.TrimEnd(':')
    $freeGb = [math]::Round((Get-PSDrive -Name $sysDrive).Free / 1GB, 1)
    if ($freeGb -ge 10) {
        Add-Result 'Free disk space' 'PASS' ("{0} GB free on {1}:" -f $freeGb, $sysDrive)
    }
    else {
        Add-Result 'Free disk space' 'FAIL' ("{0} GB free on {1}:; need 10 GB" -f $freeGb, $sysDrive)
    }
}
catch {
    Add-Result 'Free disk space' 'INFO' ("could not read: {0}" -f $_.Exception.Message)
}

# 4. WSL present
$wslPresent = $false
if (Get-Command -Name wsl.exe -ErrorAction SilentlyContinue) {
    $status = Invoke-Wsl -Arguments @('--status')
    if ($status.ExitCode -eq 0) {
        $wslPresent = $true
        Add-Result 'WSL installed' 'PASS' 'wsl --status returned 0'
    }
    else {
        Add-Result 'WSL installed' 'FAIL' 'wsl.exe exists but WSL is not set up - see step 2'
    }
}
else {
    Add-Result 'WSL installed' 'FAIL' 'wsl.exe not found - see step 2'
}

# 5. Distro present and on WSL version 2
$distroOk = $false
if ($wslPresent) {
    $list = Invoke-Wsl -Arguments @('-l', '-v')
    $line = ($list.Text -split "`n") | Where-Object { $_ -match ('\b' + [regex]::Escape($Distro) + '\b') } | Select-Object -First 1
    if (-not $line) {
        Add-Result 'Ubuntu distro' 'FAIL' ("{0} not installed - see step 2" -f $Distro)
    }
    elseif ($line -match '\s2\s*$') {
        $distroOk = $true
        Add-Result 'Ubuntu distro' 'PASS' ("{0} on WSL 2" -f $Distro)
    }
    else {
        Add-Result 'Ubuntu distro' 'FAIL' ("{0} is not on WSL 2 - run: wsl.exe --set-version {0} 2" -f $Distro)
    }
}
else {
    Add-Result 'Ubuntu distro' 'FAIL' 'skipped, WSL not installed'
}

# 6. systemd as PID 1, 7. Docker Engine, 8. Docker Compose
if ($distroOk) {
    $pid1 = Invoke-Wsl -Arguments @('-d', $Distro, '--', 'ps', '-p', '1', '-o', 'comm=')
    if ($pid1.Text -eq 'systemd') {
        Add-Result 'systemd in WSL' 'PASS' 'PID 1 is systemd'
    }
    else {
        Add-Result 'systemd in WSL' 'FAIL' ("PID 1 is '{0}' - see step 4" -f $pid1.Text)
    }

    $dv = Invoke-Wsl -Arguments @('-d', $Distro, '--', 'docker', 'version', '--format', '{{.Server.Version}}')
    if ($dv.ExitCode -eq 0 -and $dv.Text -match '^\d+\.\d+') {
        Add-Result 'Docker in WSL' 'PASS' ("Docker Engine {0}" -f $dv.Text)
    }
    elseif ($dv.Text -match 'permission denied') {
        Add-Result 'Docker in WSL' 'FAIL' 'installed, but user not yet in docker group - reopen Ubuntu (step 5)'
    }
    else {
        Add-Result 'Docker in WSL' 'FAIL' 'Docker Engine not available - see step 5'
    }

    $dc = Invoke-Wsl -Arguments @('-d', $Distro, '--', 'docker', 'compose', 'version', '--short')
    if ($dc.ExitCode -eq 0 -and $dc.Text -match '^v?\d+\.\d+') {
        Add-Result 'Docker Compose' 'PASS' ("Compose {0}" -f $dc.Text)
    }
    else {
        Add-Result 'Docker Compose' 'FAIL' 'docker compose plugin not available - see step 5'
    }
}
else {
    Add-Result 'systemd in WSL' 'FAIL' 'skipped, distro not ready'
    Add-Result 'Docker in WSL' 'FAIL' 'skipped, distro not ready'
    Add-Result 'Docker Compose' 'FAIL' 'skipped, distro not ready'
}

# 9. Docker Desktop is not the Office-IT default; report it if found.
if ($env:ProgramFiles -and (Test-Path -Path (Join-Path -Path $env:ProgramFiles -ChildPath 'Docker\Docker\Docker Desktop.exe'))) {
    Add-Result 'Docker Desktop' 'INFO' 'installed - not the Office-IT default, check with a senior'
}

# Output: fixed-width table rendered by hand, so it also works without a console.
$w1 = 18
$w2 = 6
Write-Output ("Test-OitContainerHost v{0}  {1}  {2}" -f $ScriptVersion, $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm'))
Write-Output ("{0} {1} {2}" -f 'Check'.PadRight($w1), 'Status'.PadRight($w2), 'Detail')
Write-Output ("{0} {1} {2}" -f ('-' * $w1), ('-' * $w2), ('-' * 40))
foreach ($r in $results) {
    Write-Output ("{0} {1} {2}" -f $r.Check.PadRight($w1), $r.Status.PadRight($w2), $r.Detail)
}

$failCount = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
if ($results.Count -eq 0) {
    Write-Output 'RESULT: NOT READY - no checks ran'
    exit 1
}
elseif ($failCount -eq 0) {
    Write-Output ("RESULT: READY - {0} checks, 0 failed" -f $results.Count)
    exit 0
}
else {
    Write-Output ("RESULT: NOT READY - {0} of {1} checks failed" -f $failCount, $results.Count)
    exit 1
}
