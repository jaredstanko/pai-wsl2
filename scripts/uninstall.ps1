# PAI-WSL2 -- Clean Removal
# Removes the WSL2 distro and optionally the workspace data.
#
# What this removes:
#   - WSL2 distro (wsl --unregister)
#   - Desktop/Start Menu shortcuts (if any)
#   - Optionally: workspace data at %USERPROFILE%\pai-workspace\
#
# What this does NOT remove:
#   - WSL2 itself
#   - Windows Terminal
#   - Other WSL distros
#
# Usage:
#   .\scripts\uninstall.ps1                  # Uninstall default instance
#   .\scripts\uninstall.ps1 -Name v2         # Uninstall named instance
#
# PowerShell 5.1 compatible.

param(
    [string]$Name = '',
    [int]$Port = 0
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\common.ps1"

# ─── Banner ─────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host ("=" * 50) -ForegroundColor Red
Write-Host "  PAI-WSL2 -- Uninstall" -ForegroundColor White
if ($InstanceSuffix) {
    Write-Host "  Instance: $DistroName" -ForegroundColor Red
}
Write-Host ("=" * 50) -ForegroundColor Red
Write-Host ""
Write-Host "  This will remove the PAI WSL2 distro from your system."
Write-Host "  Target: distro '$DistroName', workspace '$Workspace\'"
Write-Host ""

# ─── Step 1: Terminate and unregister the WSL2 distro ──────────────────────

Step "1/3" "WSL2 Distro"

$status = Get-PaiDistroStatus
if ($status -eq 'NotFound') {
    Skip "Distro '$DistroName' does not exist"
}
else {
    # Terminate if running
    if ($status -eq 'Running') {
        Write-Host "        Terminating distro..."
        wsl.exe -t $DistroName 2>$null
        Start-Sleep -Seconds 2
        Ok "Distro terminated"
    }

    # Unregister (this deletes the ext4 vhdx)
    Write-Host "        Unregistering distro '$DistroName'..."
    wsl.exe --unregister $DistroName 2>$null
    if ($LASTEXITCODE -eq 0) {
        Ok "Distro '$DistroName' unregistered"
    }
    else {
        Fail "Failed to unregister distro '$DistroName'"
    }
}

# ─── Step 2: Remove shortcuts ──────────────────────────────────────────────

Step "2/3" "Shortcuts and configuration"

$removedItems = 0

# Derive shortcut name to match install.ps1 convention
if ($Name -and $Name -ne '') {
    $shortcutName = "PAI ($Name)"
} else {
    $shortcutName = "PAI"
}

# Desktop shortcut (PAI session launcher)
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) "$shortcutName.lnk"
if (Test-Path $desktopShortcut) {
    Remove-Item $desktopShortcut -Force
    Ok "Removed desktop shortcut"
    $removedItems++
}

# Desktop workspace folder shortcut
if ($Name -and $Name -ne '') { $wsShortcutName = "PAI Workspace ($Name)" } else { $wsShortcutName = "PAI Workspace" }
$workspaceShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) "$wsShortcutName.lnk"
if (Test-Path $workspaceShortcut) {
    Remove-Item $workspaceShortcut -Force
    Ok "Removed workspace folder shortcut"
    $removedItems++
}

# Start Menu shortcut
$startMenuShortcut = Join-Path ([Environment]::GetFolderPath('Programs')) "$shortcutName.lnk"
if (Test-Path $startMenuShortcut) {
    Remove-Item $startMenuShortcut -Force
    Ok "Removed Start Menu shortcut"
    $removedItems++
}

# PAI_WORKSPACE environment variable
if ([Environment]::GetEnvironmentVariable('PAI_WORKSPACE', 'User')) {
    [Environment]::SetEnvironmentVariable('PAI_WORKSPACE', $null, 'User')
    Ok "Removed PAI_WORKSPACE environment variable"
    $removedItems++
}

# Log file
if (Test-Path $LogFile) {
    Remove-Item $LogFile -Force
    Ok "Removed log file ($LogFile)"
    $removedItems++
}

if ($removedItems -eq 0) {
    Skip "No shortcuts or config files found"
}

# ─── Step 3: Workspace data (ASKS FIRST) ──────────────────────────────────

Step "3/3" "Workspace data"

if (Test-Path $Workspace -PathType Container) {
    Write-Host ""
    Write-Host "        WARNING: $Workspace\ contains your data!" -ForegroundColor Red
    Write-Host ""
    Write-Host "        This includes:"
    Write-Host "          (claude-home lives inside WSL2 at /home/claude/)"
    Write-Host "          - work\        -- Projects and work-in-progress"
    Write-Host "          - data\        -- Persistent data"
    Write-Host "          - exchange\    -- File exchange"
    Write-Host "          - portal\      -- Web portal content"
    Write-Host "          - upstream\    -- Reference repos"
    Write-Host ""

    # Show directory sizes
    Write-Host "        Directory sizes:"
    $subdirs = Get-ChildItem -Path $Workspace -Directory -ErrorAction SilentlyContinue
    foreach ($subdir in $subdirs) {
        $size = "{0:N1} MB" -f ((Get-ChildItem -Path $subdir.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB)
        Write-Host ("          {0,-12} {1}" -f $subdir.Name, $size)
    }
    Write-Host ""

    $confirm = Read-Host "        Delete $Workspace\ and ALL its contents? [y/N]"
    if ($confirm -eq 'y' -or $confirm -eq 'Y') {
        Remove-Item -Path $Workspace -Recurse -Force
        Ok "Removed $Workspace\"
    }
    else {
        Warn "Kept $Workspace\ -- you can remove it manually later"
    }
}
else {
    Skip "$Workspace\ (not found)"
}

# ─── Done ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host ("=" * 50) -ForegroundColor Green
Write-Host "  Cleanup complete" -ForegroundColor Green
Write-Host ("=" * 50) -ForegroundColor Green
Write-Host ""
Write-Host "  What was removed:"
Write-Host "    - WSL2 distro '$DistroName'"
Write-Host "    - Desktop/Start Menu shortcuts"
Write-Host ""
Write-Host "  What was NOT removed:"
Write-Host "    - WSL2 itself"
Write-Host "    - Windows Terminal"
Write-Host "    - This repo (pai-wsl2\)"
if (Test-Path $Workspace -PathType Container) {
    Write-Host "    - $Workspace\ (you chose to keep it)"
}
Write-Host ""
$reinstallCmd = ".\install.ps1"
if ($Name) {
    $reinstallCmd += " -Name $Name"
}
Write-Host "  To do a fresh install: $reinstallCmd"
Write-Host ""
