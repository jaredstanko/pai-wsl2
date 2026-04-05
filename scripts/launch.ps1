# PAI-WSL2 — Launch PAI sessions
# Opens a Windows Terminal tab (or falls back to wsl.exe) running PAI.
#
# Usage:
#   .\scripts\launch.ps1                     # Launch PAI (default)
#   .\scripts\launch.ps1 -Resume             # Resume a previous Claude Code session
#   .\scripts\launch.ps1 -Shell              # Open a plain bash shell
#   .\scripts\launch.ps1 -Name v2            # Target a named instance
#   .\scripts\launch.ps1 -Name v2 -Shell     # Shell into a named instance
#
# PowerShell 5.1 compatible.

param(
    [string]$Name = '',
    [int]$Port = 0,
    [switch]$Resume,
    [switch]$Shell
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\common.ps1"

# ─── Ensure distro is running ──────────────────────────────────────────────
$status = Get-PaiDistroStatus
if ($status -eq 'NotFound') {
    Write-Host "Distro '$DistroName' does not exist. Run install.ps1 first." -ForegroundColor Red
    exit 1
}
if ($status -ne 'Running') {
    Write-Host "Starting distro '$DistroName'..."
    wsl.exe -d $DistroName -- echo 'started' | Out-Null
    Start-Sleep -Seconds 1
    Write-Host "Distro started." -ForegroundColor Green
}

# ─── Determine action ──────────────────────────────────────────────────────
$titlePrefix = $DistroName.ToUpper()

if ($Resume) {
    $action  = 'resume'
    $title   = "$titlePrefix: Resume"
    $bashCmd = 'claude -r'
}
elseif ($Shell) {
    $action  = 'shell'
    $title   = "$titlePrefix: Shell"
    $bashCmd = ''
}
else {
    $action  = 'pai'
    $title   = "$titlePrefix"
    $bashCmd = 'bun ~/.claude/PAI/Tools/pai.ts'
}

# ─── Check for Windows Terminal ─────────────────────────────────────────────
$hasWT = $null -ne (Get-Command wt.exe -ErrorAction SilentlyContinue)

# ─── Launch ─────────────────────────────────────────────────────────────────
if ($action -eq 'shell') {
    Write-Host "Opening shell..."
    if ($hasWT) {
        wt.exe -w 0 new-tab --title $title -- wsl.exe -d $DistroName -- bash -l
    }
    else {
        Write-Host "(Windows Terminal not found — launching directly)" -ForegroundColor Yellow
        Start-Process wsl.exe -ArgumentList "-d", $DistroName, "--", "bash", "-l"
    }
}
else {
    if ($action -eq 'resume') {
        Write-Host "Opening session picker..."
    }
    else {
        Write-Host "Launching PAI..."
    }

    if ($hasWT) {
        wt.exe -w 0 new-tab --title $title -- wsl.exe -d $DistroName -- bash -lc $bashCmd
    }
    else {
        Write-Host "(Windows Terminal not found — launching directly)" -ForegroundColor Yellow
        Start-Process wsl.exe -ArgumentList "-d", $DistroName, "--", "bash", "-lc", $bashCmd
    }
}

Write-Host ""
Write-Host "Portal: http://localhost:$PortalPort"
