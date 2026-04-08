# PAI-WSL2 -- Host-Side Verification
# Checks that the full system is installed and functional from the Windows side,
# then runs verify.sh inside the distro for WSL-side checks.
#
# Usage:
#   .\scripts\verify.ps1                     # Verify default instance
#   .\scripts\verify.ps1 -Name v2            # Verify named instance
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
$script:FailCount = 0

function Passed {
    param(
        [string]$Label,
        [string]$Detail = ''
    )
    $msg = "  "
    Write-Host $msg -NoNewline
    Write-Host "PASS    " -ForegroundColor Green -NoNewline
    if ($Detail) {
        Write-Host ("{0,-40} {1}" -f $Label, $Detail)
    }
    else {
        Write-Host $Label
    }
    $script:PassCount++
}

function Failed {
    param(
        [string]$Label,
        [string]$Detail = ''
    )
    $msg = "  "
    Write-Host $msg -NoNewline
    Write-Host "FAIL    " -ForegroundColor Red -NoNewline
    if ($Detail) {
        Write-Host ("{0,-40} {1}" -f $Label, $Detail)
    }
    else {
        Write-Host $Label
    }
    $script:FailCount++
}

# ─── Banner ─────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host ("=" * 50) -ForegroundColor Cyan
Write-Host "  PAI-WSL2 -- System Verification" -ForegroundColor White
if ($InstanceSuffix) {
    Write-Host "  Instance: $DistroName" -ForegroundColor Cyan
}
Write-Host ("=" * 50) -ForegroundColor Cyan
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# HOST CHECKS (Windows)
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "  Host (Windows)" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────────"

# Windows version
$osVersion = [System.Environment]::OSVersion.Version
$osBuild = $osVersion.Build
if ($osBuild -ge 19041) {
    Passed "Windows version" "($osBuild -- WSL2 supported)"
}
else {
    Failed "Windows version" "($osBuild -- WSL2 requires build 19041+)"
}

# WSL2 enabled
$wslOutput = $null
try {
    $wslOutput = wsl.exe --status 2>&1
    if ($LASTEXITCODE -eq 0) {
        Passed "WSL2 enabled"
    }
    else {
        Failed "WSL2 enabled" "(wsl --status failed)"
    }
}
catch {
    Failed "WSL2 enabled" "(wsl.exe not found)"
}

# Distro exists and running
$distroStatus = Get-PaiDistroStatus
if ($distroStatus -eq 'Running') {
    Passed "Distro '$DistroName'" "(running)"
}
elseif ($distroStatus -eq 'Stopped') {
    Failed "Distro '$DistroName'" "(stopped -- expected running)"
}
else {
    Failed "Distro '$DistroName'" "(not found)"
}

# Windows Terminal
$wtPath = Get-Command wt.exe -ErrorAction SilentlyContinue
if ($wtPath) {
    Passed "Windows Terminal" "(wt.exe found)"
}
else {
    Failed "Windows Terminal" "(wt.exe not found -- optional but recommended)"
}

# Workspace directories
$workspaceDirs = @('data', 'exchange', 'portal', 'work', 'upstream')
$allDirsExist = $true
foreach ($dir in $workspaceDirs) {
    $dirPath = Join-Path $Workspace $dir
    if (-not (Test-Path $dirPath -PathType Container)) {
        $allDirsExist = $false
        Failed "Workspace: $dir" "(not found: $dirPath)"
    }
}
if ($allDirsExist) {
    Passed "Workspace directories (6/6)" "($Workspace\)"
}

# ═══════════════════════════════════════════════════════════════════════════
# WSL CHECKS (delegated to verify.sh inside the distro)
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  WSL2 Distro ($DistroName)" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────────"

if ($distroStatus -eq 'NotFound') {
    Failed "WSL2 distro '$DistroName'" "(does not exist -- cannot run internal checks)"
}
elseif ($distroStatus -ne 'Running') {
    Failed "WSL2 distro '$DistroName'" "(not running -- cannot run internal checks)"
}
else {
    # Copy verify.sh into the distro and run it, parsing its output
    $verifyScript = Join-Path $ScriptDir 'verify.sh'
    if (Test-Path $verifyScript) {
        # Copy verify.sh into distro and run it (can't use /mnt/c/ -- automount disabled)
        $verifyContent = Get-Content $verifyScript -Raw
        wsl.exe -d $DistroName -u root -- bash -c "cat > /tmp/verify.sh << 'VERIFY_EOF'
$verifyContent
VERIFY_EOF"
        wsl.exe -d $DistroName -u root -- bash -c "chmod +x /tmp/verify.sh"
        $output = wsl.exe -d $DistroName -u claude -- bash /tmp/verify.sh 2>&1

        # Display the raw output from verify.sh and count its PASS/FAIL
        foreach ($line in $output) {
            $lineStr = "$line"
            Write-Host $lineStr
            if ($lineStr -match 'PASS') {
                $script:PassCount++
            }
            elseif ($lineStr -match 'FAIL') {
                $script:FailCount++
            }
        }
    }
    else {
        Failed "verify.sh" "(not found at $verifyScript)"
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ──────────────────────────────────────────────"
$total = $script:PassCount + $script:FailCount
Write-Host -NoNewline "  "
Write-Host -NoNewline "$($script:PassCount) PASS" -ForegroundColor Green
Write-Host -NoNewline "  "
Write-Host -NoNewline "$($script:FailCount) FAIL" -ForegroundColor Red
Write-Host "  ($total checks)"
Write-Host ""

if ($script:FailCount -gt 0) {
    Write-Host "  Some checks failed. Review output above for details." -ForegroundColor Red
    Write-Host "  Re-run install.ps1 to fix, or check $LogFile"
    exit 1
}
else {
    Write-Host "  All checks passed." -ForegroundColor Green
    exit 0
}
