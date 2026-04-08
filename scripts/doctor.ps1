# PAI-WSL2 -- Health Check (Doctor)
# Comprehensive diagnostic command that checks all aspects of the PAI-WSL2
# installation and provides actionable suggestions for each issue found.
#
# Checks:
#   - WSL2 version and status
#   - Distro health (running, systemd)
#   - Clock drift (Windows vs WSL2 time)
#   - Networking mode (NAT vs mirrored)
#   - Windows Defender exclusion status
#   - Audio (WSLg PulseAudio socket)
#   - Filesystem (all mount points)
#   - Memory (.wslconfig limits vs actual)
#
# Usage:
#   .\scripts\doctor.ps1                     # Check default instance
#   .\scripts\doctor.ps1 -Name v2            # Check named instance
#
# PowerShell 5.1 compatible.

param(
    [string]$Name = '',
    [int]$Port = 0
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\common.ps1"

# ─── State ──────────────────────────────────────────────────────────────────
$script:PassCount = 0
$script:WarnCount = 0
$script:FailCount = 0
$script:Suggestions = @()

function DoctorPass {
    param([string]$Label, [string]$Detail = '')
    Write-Host -NoNewline "  "
    Write-Host -NoNewline "PASS " -ForegroundColor Green
    if ($Detail) {
        Write-Host ("{0,-42} {1}" -f $Label, $Detail)
    }
    else {
        Write-Host $Label
    }
    $script:PassCount++
}

function DoctorWarn {
    param([string]$Label, [string]$Detail = '', [string]$Suggestion = '')
    Write-Host -NoNewline "  "
    Write-Host -NoNewline "WARN " -ForegroundColor Yellow
    if ($Detail) {
        Write-Host ("{0,-42} {1}" -f $Label, $Detail)
    }
    else {
        Write-Host $Label
    }
    $script:WarnCount++
    if ($Suggestion) {
        $script:Suggestions += "  - $Label : $Suggestion"
    }
}

function DoctorFail {
    param([string]$Label, [string]$Detail = '', [string]$Suggestion = '')
    Write-Host -NoNewline "  "
    Write-Host -NoNewline "FAIL " -ForegroundColor Red
    if ($Detail) {
        Write-Host ("{0,-42} {1}" -f $Label, $Detail)
    }
    else {
        Write-Host $Label
    }
    $script:FailCount++
    if ($Suggestion) {
        $script:Suggestions += "  - $Label : $Suggestion"
    }
}

# ─── Banner ─────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host ("=" * 55) -ForegroundColor Cyan
Write-Host "  PAI-WSL2 -- Doctor (Health Check)" -ForegroundColor White
if ($InstanceSuffix) {
    Write-Host "  Instance: $DistroName" -ForegroundColor Cyan
}
Write-Host ("=" * 55) -ForegroundColor Cyan
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# 1. WSL2 VERSION AND STATUS
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "  WSL2 Platform" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────────"

# WSL version
try {
    $wslVersion = wsl.exe --version 2>&1
    $wslKernel = ($wslVersion | Select-String 'WSL.*:' | Select-Object -First 1).ToString().Trim()
    if ($wslKernel) {
        DoctorPass "WSL2 installed" "($wslKernel)"
    }
    else {
        DoctorPass "WSL2 installed"
    }
}
catch {
    DoctorFail "WSL2 installed" "(wsl.exe not found)" "Install WSL2: wsl --install"
}

# Windows build
$osBuild = [System.Environment]::OSVersion.Version.Build
if ($osBuild -ge 22000) {
    DoctorPass "Windows 11" "(build $osBuild -- WSLg supported)"
}
elseif ($osBuild -ge 19041) {
    DoctorWarn "Windows 10" "(build $osBuild -- no WSLg, no audio/GUI passthrough)" "Upgrade to Windows 11 for WSLg audio and GUI support"
}
else {
    DoctorFail "Windows version" "(build $osBuild -- WSL2 requires 19041+)" "Update Windows to build 19041 or later"
}

# ═══════════════════════════════════════════════════════════════════════════
# 2. DISTRO HEALTH
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Distro Health" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────────"

$distroStatus = Get-PaiDistroStatus

if ($distroStatus -eq 'NotFound') {
    DoctorFail "Distro '$DistroName'" "(not found)" "Run install.ps1 to create the distro"
    # Can't do further WSL checks without a distro
    Write-Host ""
    Write-Host "  Cannot run distro-internal checks -- distro does not exist." -ForegroundColor Yellow
}
else {
    if ($distroStatus -eq 'Running') {
        DoctorPass "Distro '$DistroName'" "(running)"
    }
    else {
        DoctorWarn "Distro '$DistroName'" "(status: $distroStatus)" "Start with: wsl -d $DistroName"
    }

    # Systemd check (only if running)
    if ($distroStatus -eq 'Running') {
        $systemdPid = wsl.exe -d $DistroName -- bash -c "ps -p 1 -o comm= 2>/dev/null" 2>&1
        $systemdPid = "$systemdPid".Trim()
        if ($systemdPid -eq 'systemd') {
            DoctorPass "systemd" "(PID 1 is systemd)"
        }
        else {
            DoctorWarn "systemd" "(PID 1 is $systemdPid)" "Add [boot] systemd=true to /etc/wsl.conf and restart"
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# 3. CLOCK DRIFT
# ═══════════════════════════════════════════════════════════════════════════

if ($distroStatus -eq 'Running') {
    Write-Host ""
    Write-Host "  Clock Drift" -ForegroundColor White
    Write-Host "  ──────────────────────────────────────────────"

    $windowsEpoch = [int][double]::Parse((Get-Date -UFormat %s))
    $wslEpoch = wsl.exe -d $DistroName -- date +%s 2>&1
    $wslEpochInt = 0
    if ([int]::TryParse("$wslEpoch".Trim(), [ref]$wslEpochInt)) {
        $drift = [Math]::Abs($windowsEpoch - $wslEpochInt)
        if ($drift -le 5) {
            DoctorPass "Clock sync" "(drift: ${drift}s)"
        }
        elseif ($drift -le 30) {
            DoctorWarn "Clock drift" "(${drift}s difference)" "Run inside WSL: sudo hwclock -s"
        }
        else {
            DoctorFail "Clock drift" "(${drift}s difference!)" "Run: wsl -d $DistroName -- sudo hwclock -s"
        }
    }
    else {
        DoctorWarn "Clock check" "(could not read WSL time)"
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# 4. NETWORKING MODE
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Networking" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────────"

$wslConfigPath = Join-Path $env:USERPROFILE '.wslconfig'
$networkMode = 'NAT'  # default

if (Test-Path $wslConfigPath) {
    $wslConfig = Get-Content $wslConfigPath -Raw
    if ($wslConfig -match 'networkingMode\s*=\s*mirrored') {
        $networkMode = 'mirrored'
    }
    DoctorPass ".wslconfig found" "(networking: $networkMode)"
}
else {
    DoctorWarn ".wslconfig" "(not found -- using defaults)" "Create $wslConfigPath to configure memory/network limits"
}

if ($networkMode -eq 'mirrored') {
    DoctorPass "Networking mode" "(mirrored -- localhost shared)"
}
else {
    DoctorPass "Networking mode" "(NAT -- default)"
}

# ═══════════════════════════════════════════════════════════════════════════
# 5. WINDOWS DEFENDER EXCLUSIONS
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Windows Defender" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────────"

# Check if we can query Defender (requires elevation for full check)
$pathsToCheck = @($Workspace)
# Also check the WSL vhdx location
$vhdxDir = Join-Path $env:LOCALAPPDATA "PAI\$DistroName"
if (Test-Path $vhdxDir) {
    $pathsToCheck += $vhdxDir
}

try {
    $exclusions = (Get-MpPreference -ErrorAction Stop).ExclusionPath
    if ($null -eq $exclusions) {
        $exclusions = @()
    }

    foreach ($checkPath in $pathsToCheck) {
        $isExcluded = $false
        foreach ($exc in $exclusions) {
            if ($checkPath.StartsWith($exc, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isExcluded = $true
                break
            }
        }
        $shortPath = $checkPath
        if ($isExcluded) {
            DoctorPass "Defender exclusion" "($shortPath)"
        }
        else {
            DoctorWarn "Defender exclusion" "($shortPath not excluded)" "Add exclusion for better I/O: Add-MpPreference -ExclusionPath '$checkPath'"
        }
    }
}
catch {
    DoctorWarn "Defender check" "(requires elevation to query)" "Run as Administrator to check Defender exclusions"
}

# ═══════════════════════════════════════════════════════════════════════════
# 6. AUDIO (WSLg PulseAudio)
# ═══════════════════════════════════════════════════════════════════════════

if ($distroStatus -eq 'Running') {
    Write-Host ""
    Write-Host "  Audio (WSLg)" -ForegroundColor White
    Write-Host "  ──────────────────────────────────────────────"

    $pulseSocket = wsl.exe -d $DistroName -- bash -c "test -e /mnt/wslg/PulseServer && echo YES || echo NO" 2>&1
    $pulseSocket = "$pulseSocket".Trim()
    if ($pulseSocket -eq 'YES') {
        DoctorPass "WSLg PulseAudio socket" "(/mnt/wslg/PulseServer)"
    }
    else {
        DoctorWarn "WSLg PulseAudio socket" "(not found)" "WSLg requires Windows 11. Audio passthrough is not available on Windows 10."
    }

    # Check if say shim exists
    $sayExists = wsl.exe -d $DistroName -- bash -c "command -v say >/dev/null 2>&1 && echo YES || echo NO" 2>&1
    $sayExists = "$sayExists".Trim()
    if ($sayExists -eq 'YES') {
        DoctorPass "say shim" "(installed)"
    }
    else {
        DoctorWarn "say shim" "(not found)" "Re-run provision.sh to install audio shims"
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# 7. FILESYSTEM
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Filesystem" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────────"

# Windows-side workspace dirs
$workspaceDirs = @('data', 'exchange', 'portal', 'work', 'upstream')
$allExist = $true
foreach ($dir in $workspaceDirs) {
    $dirPath = Join-Path $Workspace $dir
    if (-not (Test-Path $dirPath -PathType Container)) {
        $allExist = $false
        DoctorFail "Workspace: $dir" "(not found: $dirPath)" "Run install.ps1 or create manually"
    }
}
if ($allExist) {
    DoctorPass "Workspace directories (6/6)" "($Workspace\)"
}

# WSL-side mount accessibility
if ($distroStatus -eq 'Running') {
    $mountCheck = wsl.exe -d $DistroName -- bash -c '
        ok=0; fail=0
        for d in data exchange portal work upstream; do
            if [ -d "/home/claude/$d" ] || [ -L "/home/claude/$d" ]; then
                ok=$((ok + 1))
            else
                fail=$((fail + 1))
                echo "MISSING:$d"
            fi
        done
        echo "OK:$ok"
        echo "FAIL:$fail"
    ' 2>&1

    $mountOk = 0
    $mountFail = 0
    foreach ($line in $mountCheck) {
        $lineStr = "$line".Trim()
        if ($lineStr -match '^OK:(\d+)') {
            $mountOk = [int]$Matches[1]
        }
        elseif ($lineStr -match '^FAIL:(\d+)') {
            $mountFail = [int]$Matches[1]
        }
        elseif ($lineStr -match '^MISSING:(.+)') {
            DoctorFail "WSL symlink: ~/$($Matches[1])" "(missing)" "Re-run provision.sh to create symlinks"
        }
    }
    if ($mountFail -eq 0 -and $mountOk -gt 0) {
        DoctorPass "WSL symlinks ($mountOk/5)" "(user dirs linked to NTFS)"
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# 8. MEMORY (.wslconfig)
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Memory" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────────"

$memoryLimit = ''
$swapLimit = ''

if (Test-Path $wslConfigPath) {
    $wslConfig = Get-Content $wslConfigPath
    foreach ($line in $wslConfig) {
        if ($line -match '^\s*memory\s*=\s*(.+)') {
            $memoryLimit = $Matches[1].Trim()
        }
        if ($line -match '^\s*swap\s*=\s*(.+)') {
            $swapLimit = $Matches[1].Trim()
        }
    }
}

if ($memoryLimit) {
    DoctorPass "Memory limit" "($memoryLimit in .wslconfig)"
}
else {
    $totalRamGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    DoctorWarn "Memory limit" "(not set -- WSL2 can use up to 50% of ${totalRamGB}GB)" "Set [wsl2] memory=8GB in $wslConfigPath"
}

if ($swapLimit) {
    DoctorPass "Swap limit" "($swapLimit in .wslconfig)"
}
else {
    DoctorWarn "Swap limit" "(not set -- defaults to 25% of RAM)" "Set [wsl2] swap=4GB in $wslConfigPath"
}

# Actual memory usage inside WSL
if ($distroStatus -eq 'Running') {
    $memInfo = wsl.exe -d $DistroName -- bash -c "free -h 2>/dev/null | grep Mem | awk '{print \$2,\$3}'" 2>&1
    $memInfo = "$memInfo".Trim()
    if ($memInfo) {
        $parts = $memInfo -split '\s+'
        if ($parts.Count -ge 2) {
            DoctorPass "Actual memory usage" "(used: $($parts[1]) / total: $($parts[0]))"
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ──────────────────────────────────────────────"
$total = $script:PassCount + $script:WarnCount + $script:FailCount
Write-Host -NoNewline "  "
Write-Host -NoNewline "$($script:PassCount) PASS" -ForegroundColor Green
Write-Host -NoNewline "  "
Write-Host -NoNewline "$($script:WarnCount) WARN" -ForegroundColor Yellow
Write-Host -NoNewline "  "
Write-Host -NoNewline "$($script:FailCount) FAIL" -ForegroundColor Red
Write-Host "  ($total checks)"
Write-Host ""

# Actionable suggestions
if ($script:Suggestions.Count -gt 0) {
    Write-Host "  Suggestions:" -ForegroundColor Yellow
    foreach ($suggestion in $script:Suggestions) {
        Write-Host $suggestion
    }
    Write-Host ""
}

if ($script:FailCount -gt 0) {
    Write-Host "  Some checks failed. Address the issues above and re-run doctor." -ForegroundColor Red
    exit 1
}
elseif ($script:WarnCount -gt 0) {
    Write-Host "  System is functional with some warnings." -ForegroundColor Yellow
    exit 0
}
else {
    Write-Host "  All checks passed. System is healthy." -ForegroundColor Green
    exit 0
}
