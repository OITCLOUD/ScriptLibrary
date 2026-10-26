<#
.SYNOPSIS
    Phase 2 of the Office-IT container workstation rollout: imports Ubuntu into WSL for the
    logged-on user, creates the Linux user, enables systemd and installs Docker Engine.

.DESCRIPTION
    WSL distros are per Windows user, so this must run in the user's own context, not as SYSTEM.
    No admin rights needed. Idempotent: every step checks first and skips what is already done.

    Ubuntu is imported from a WSL root filesystem tarball (wsl --import), which is fully
    non-interactive. Stage the tarball once on an internal share or web location and pass it
    in RootfsSource. Optionally pass its SHA256 to verify the copy.

    NinjaOne: script library, language PowerShell, Run As: Current Logged on User.
              Script variables 'rootfsSource' and 'rootfsSha256' are read from the environment.
    Manual:   save as Install-OitWslDocker.ps1 and run as the user (not elevated):
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-OitWslDocker.ps1 -RootfsSource \\server\share\ubuntu-26.04.1-wsl-amd64.wsl

.NOTES
    Script  : Install-OitWslDocker.ps1
    Version : 0.2.1
    Date    : 2026-10-18
    Target  : Windows PowerShell 5.1
    Run as  : the logged-on user (NOT SYSTEM, not elevated)
    Requires: Install-OitWslPlatform.ps1 completed with RESULT: OK
    Embeds  : wsl-bootstrap-root.sh v0.2.0, install-docker-engine.sh v0.2.0
    Exit    : 0 = RESULT: OK, 1 = RESULT: FAILED
#>
[CmdletBinding()]
param(
    [string]$RootfsSource = $env:rootfsSource,
    [string]$RootfsSha256 = $env:rootfsSha256,
    [string]$Distro = 'Ubuntu-26.04'
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '0.2.1'
$env:WSL_UTF8 = '1'
$wslExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\wsl.exe'

# Embedded Linux scripts (single source: scripts/*.sh in the skill; keep in sync on version bumps)
$BootstrapScript = @'
#!/usr/bin/env bash
# wsl-bootstrap-root.sh
# Version : 0.2.0 (2026-10-18)
# Purpose : Prepare an imported WSL Ubuntu distro: create the Linux user, passwordless sudo,
#           systemd and default user in /etc/wsl.conf. Idempotent.
# Run     : as root inside WSL:  bash wsl-bootstrap-root.sh <linux-username>
#           (Install-OitWslDocker.ps1 does this automatically)
# Result  : last line RESULT: PASS or RESULT: FAIL, exit code 0 or 1.
# Note    : NOPASSWD sudo inside WSL grants no extra rights on Windows; root in WSL runs
#           with the same Windows permissions as the user who started WSL.
set -euo pipefail

fail() { echo "FAIL $1"; echo "RESULT: FAIL - $1"; exit 1; }
ok()   { echo "PASS $1"; }

echo "wsl-bootstrap-root.sh v0.2.0"

name="${1:-}"
[ -n "$name" ] || fail "usage: wsl-bootstrap-root.sh <linux-username>"
echo "$name" | grep -Eq '^[a-z][a-z0-9_-]{0,31}$' || fail "invalid username '$name'"
[ "$(id -u)" -eq 0 ] || fail "must run as root"

if ! command -v sudo >/dev/null 2>&1; then
  apt-get update && apt-get install -y sudo || fail "could not install sudo"
fi
ok "sudo available"

if id -u "$name" >/dev/null 2>&1; then
  ok "user $name already exists"
else
  useradd --create-home --shell /bin/bash --groups sudo "$name" || fail "useradd failed"
  ok "user $name created"
fi

sudoers="/etc/sudoers.d/90-oit-wsl"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$name" > "$sudoers"
chmod 0440 "$sudoers"
visudo -cf "$sudoers" >/dev/null || { rm -f "$sudoers"; fail "sudoers file did not validate"; }
ok "passwordless sudo for $name"

printf '[boot]\nsystemd=true\n\n[user]\ndefault=%s\n' "$name" > /etc/wsl.conf
grep -q '^systemd=true$' /etc/wsl.conf || fail "wsl.conf not written"
grep -q "^default=$name\$" /etc/wsl.conf || fail "wsl.conf default user not written"
ok "/etc/wsl.conf: systemd on, default user $name"

echo "RESULT: PASS - bootstrap complete, restart the distro to apply wsl.conf"
'@

$DockerScript = @'
#!/usr/bin/env bash
# install-docker-engine.sh
# Version : 0.2.0 (2026-10-18)
# Purpose : Install Docker Engine + Compose plugin in WSL2 Ubuntu from Docker's official apt repository.
# Run     : bash ~/install-docker-engine.sh   (as your normal Ubuntu user; asks for sudo)
# Result  : last line is RESULT: PASS or RESULT: FAIL, exit code 0 or 1.
set -euo pipefail

fail() { echo "FAIL $1"; echo "RESULT: FAIL - $1"; exit 1; }
ok()   { echo "PASS $1"; }

echo "install-docker-engine.sh v0.2.0"

# Pre-checks
[ "$(id -u)" -ne 0 ] || fail "run as your normal user, not as root"
grep -qi microsoft /proc/version || fail "this does not look like WSL"
. /etc/os-release
[ "${ID:-}" = "ubuntu" ] || fail "expected Ubuntu, found ${ID:-unknown}"
ok "Ubuntu ${VERSION_ID} in WSL"

[ "$(ps -p 1 -o comm=)" = "systemd" ] || fail "systemd is not running (PID 1) - see step 4"
ok "systemd is PID 1"

# Remove conflicting distro packages if present (no error if absent)
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    sudo apt-get remove -y "$pkg"
  fi
done

# Docker apt repository
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
  || fail "could not download Docker GPG key (TLS inspection? see Known problems)"
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
ok "packages installed"

sudo systemctl enable --now docker
systemctl is-active --quiet docker || fail "docker service is not active"
ok "docker service active"

me="${USER:-$(id -un)}"
sudo usermod -aG docker "$me"
ok "user $me added to docker group (takes effect after reopening Ubuntu)"

# Verification - expected output contains 'Hello from Docker!'
if sudo docker run --rm hello-world | grep -q 'Hello from Docker!'; then
  ok "hello-world container ran"
else
  fail "hello-world did not print the expected text"
fi

ver="$(sudo docker version --format '{{.Server.Version}}')"
cver="$(sudo docker compose version --short)"
[ -n "$ver" ] || fail "docker version returned nothing"
[ -n "$cver" ] || fail "docker compose version returned nothing"
ok "Docker Engine $ver, Compose $cver"

echo "RESULT: PASS - Docker Engine installed and hello-world ran"
echo "Next: close this Ubuntu window and open it again, then run: docker run --rm hello-world"
'@

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

function Invoke-Wsl {
    # Local Continue: native stderr with 2>&1 under Stop is terminating in Windows PowerShell 5.1.
    param([string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $out = & $wslExe @Arguments 2>&1
    $code = $LASTEXITCODE
    $text = (($out | ForEach-Object { "$_" }) -join "`n") -replace "`0", ''
    return [pscustomobject]@{ ExitCode = $code; Text = $text.Trim() }
}

function Write-LinuxFile {
    # Writes a script with LF line endings and no BOM, so bash can run it.
    param([string]$Path, [string]$Content)
    $lf = ($Content -replace "`r`n", "`n").TrimEnd() + "`n"
    [System.IO.File]::WriteAllText($Path, $lf, (New-Object System.Text.UTF8Encoding($false)))
}

function ConvertTo-WslPath {
    # C:\ProgramData\OIT\x.sh -> /mnt/c/ProgramData/OIT/x.sh (default automount root)
    param([string]$WindowsPath)
    $full = [System.IO.Path]::GetFullPath($WindowsPath)
    return '/mnt/' + $full.Substring(0, 1).ToLower() + $full.Substring(2).Replace('\', '/')
}

function Test-DistroRegistered {
    $list = Invoke-Wsl -Arguments @('--list', '--quiet')
    $names = ($list.Text -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    return ($names -contains $Distro)
}

Write-Output ("Install-OitWslDocker v{0}  {1}  {2}\{3}  {4}" -f $ScriptVersion, $env:COMPUTERNAME, $env:USERDOMAIN, $env:USERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm'))

# 1. Context: must be a real user, not SYSTEM
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.User.Value -eq 'S-1-5-18') {
    Stop-Script 'running as SYSTEM; in NinjaOne set Run As: Current Logged on User'
}
Write-Step 'PASS' ("running as {0}" -f $identity.Name)

# 2. WSL platform present (phase 1 done)
if (-not (Test-Path -Path $wslExe)) { Stop-Script 'wsl.exe not found; run Install-OitWslPlatform.ps1 first' }
$ver = Invoke-Wsl -Arguments @('--version')
if ($ver.ExitCode -ne 0) { Stop-Script 'modern WSL package not present; run Install-OitWslPlatform.ps1 first (and reboot)' }
Write-Step 'PASS' 'WSL platform present'

# 3. Linux username derived from the Windows username
$linuxUser = ($env:USERNAME.ToLower() -replace '[^a-z0-9_-]', '')
if ($linuxUser -notmatch '^[a-z]') { $linuxUser = 'u' + $linuxUser }
if ($linuxUser.Length -gt 32) { $linuxUser = $linuxUser.Substring(0, 32) }
if ($linuxUser.Length -lt 2) { Stop-Script ("could not derive a Linux username from '{0}'" -f $env:USERNAME) }
Write-Step 'PASS' ("Linux username: {0}" -f $linuxUser)

# Work folder without spaces in the path, so it passes cleanly to bash
$work = Join-Path -Path $env:ProgramData -ChildPath ("OIT\wsl-setup\{0}" -f $linuxUser)
New-Item -ItemType Directory -Path $work -Force | Out-Null

# 4. Import the distro if not registered yet
if (Test-DistroRegistered) {
    Write-Step 'PASS' ("distro {0} already registered" -f $Distro)
}
else {
    if ([string]::IsNullOrWhiteSpace($RootfsSource)) {
        Stop-Script 'distro not installed and no RootfsSource given (NinjaOne script variable rootfsSource)'
    }
    # Keep the source file name: WSL may pick the import format from the extension (.wsl, .tar.gz)
    $leaf = (($RootfsSource -split '[\\/]')[-1] -replace '\?.*$', '')
    if ([string]::IsNullOrWhiteSpace($leaf) -or $leaf -notmatch '\.(wsl|tar|tar\.gz|tgz|tar\.xz)$') { $leaf = 'rootfs.tar.gz' }
    $tar = Join-Path -Path $work -ChildPath $leaf
    if ($RootfsSource -match '^https?://') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $RootfsSource -OutFile $tar -UseBasicParsing
    }
    else {
        Copy-Item -Path $RootfsSource -Destination $tar -Force
    }
    $size = (Get-Item -Path $tar).Length
    if ($size -lt 50MB) { Stop-Script ("rootfs copy is only {0} bytes; check RootfsSource" -f $size) }
    Write-Step 'PASS' ("rootfs copied, {0} MB" -f [math]::Round($size / 1MB))

    if (-not [string]::IsNullOrWhiteSpace($RootfsSha256)) {
        $hash = (Get-FileHash -Path $tar -Algorithm SHA256).Hash
        if ($hash -ne $RootfsSha256.Trim().ToUpper()) { Stop-Script ("SHA256 mismatch: got {0}" -f $hash) }
        Write-Step 'PASS' 'SHA256 matches'
    }
    else {
        Write-Step 'INFO' 'no SHA256 given, copy not verified'
    }

    $installDir = Join-Path -Path $env:LOCALAPPDATA -ChildPath ("OIT\WSL\{0}" -f $Distro)
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    $imp = Invoke-Wsl -Arguments @('--import', $Distro, $installDir, $tar, '--version', '2')
    Remove-Item -Path $tar -Force -ErrorAction SilentlyContinue
    if ($imp.ExitCode -ne 0 -or -not (Test-DistroRegistered)) {
        Stop-Script ("wsl --import failed (exit {0}): {1}" -f $imp.ExitCode, $imp.Text)
    }
    Write-Step 'PASS' ("distro {0} imported to {1}" -f $Distro, $installDir)
}

# 5. Bootstrap as root: user, sudo, systemd, default user
$bootPath = Join-Path -Path $work -ChildPath 'wsl-bootstrap-root.sh'
Write-LinuxFile -Path $bootPath -Content $BootstrapScript
$boot = Invoke-Wsl -Arguments @('-d', $Distro, '-u', 'root', '--', 'bash', (ConvertTo-WslPath $bootPath), $linuxUser)
Write-Output $boot.Text
if ($boot.ExitCode -ne 0 -or $boot.Text -notmatch 'RESULT: PASS') { Stop-Script 'bootstrap script did not pass' }

# Restart the distro so wsl.conf (systemd, default user) applies
Invoke-Wsl -Arguments @('--terminate', $Distro) | Out-Null
$pid1 = Invoke-Wsl -Arguments @('-d', $Distro, '--', 'ps', '-p', '1', '-o', 'comm=')
if ($pid1.Text -ne 'systemd') { Stop-Script ("systemd not running after restart (PID 1 = '{0}')" -f $pid1.Text) }
Write-Step 'PASS' 'systemd is PID 1'
$who = Invoke-Wsl -Arguments @('-d', $Distro, '--', 'id', '-un')
if ($who.Text -ne $linuxUser) { Stop-Script ("default user is '{0}', expected '{1}'" -f $who.Text, $linuxUser) }
Write-Step 'PASS' ("default user is {0}" -f $linuxUser)

# 6. Docker Engine
$dv = Invoke-Wsl -Arguments @('-d', $Distro, '--', 'docker', 'version', '--format', '{{.Server.Version}}')
if ($dv.ExitCode -eq 0 -and $dv.Text -match '^\d+\.\d+') {
    Write-Step 'PASS' ("Docker Engine {0} already installed" -f $dv.Text)
}
else {
    $dockPath = Join-Path -Path $work -ChildPath 'install-docker-engine.sh'
    Write-LinuxFile -Path $dockPath -Content $DockerScript
    $dock = Invoke-Wsl -Arguments @('-d', $Distro, '-u', $linuxUser, '--', 'bash', (ConvertTo-WslPath $dockPath))
    Write-Output $dock.Text
    if ($dock.ExitCode -ne 0 -or $dock.Text -notmatch 'RESULT: PASS') { Stop-Script 'Docker install script did not pass' }
}

# 7. Final verification as the normal user, after restart (docker group membership)
Invoke-Wsl -Arguments @('--terminate', $Distro) | Out-Null
$hello = Invoke-Wsl -Arguments @('-d', $Distro, '--', 'docker', 'run', '--rm', 'hello-world')
if ($hello.Text -notmatch 'Hello from Docker!') {
    Stop-Script ("hello-world as {0} without sudo failed: {1}" -f $linuxUser, $hello.Text)
}
Write-Step 'PASS' ("hello-world runs as {0} without sudo" -f $linuxUser)
$dc = Invoke-Wsl -Arguments @('-d', $Distro, '--', 'docker', 'compose', 'version', '--short')
if ($dc.ExitCode -ne 0) { Stop-Script 'docker compose plugin not available' }
Write-Step 'PASS' ("Docker Compose {0}" -f $dc.Text)

$set = Invoke-Wsl -Arguments @('--set-default', $Distro)
if ($set.ExitCode -eq 0) { Write-Step 'PASS' ("{0} is the default distro" -f $Distro) }

Write-Output ("RESULT: OK - {0} with Docker Engine ready for {1}" -f $Distro, $env:USERNAME)
exit 0
