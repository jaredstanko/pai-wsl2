# PAI-WSL2 — Dynamic Folder Sharing
# Since WSL2 can access all of C:\ via /mnt/c/, "mounting" means creating
# a symlink inside the distro pointing to the Windows path.
#
# Usage:
#   .\scripts\mount.ps1 C:\Projects\my-repo                    # Mount as ~/my-repo
#   .\scripts\mount.ps1 C:\Projects\my-repo /home/claude/code  # Mount at specific path
#   .\scripts\mount.ps1 -List                                  # Show current symlinks
#   .\scripts\mount.ps1 -Name v2 C:\Projects\my-repo           # Target named instance
#
# Unlike PAI-LIMA, no restart is needed — WSL2 always has /mnt/c/ available.
#
# PowerShell 5.1 compatible.

param(
    [string]$Name = '',
    [int]$Port = 0,
    [switch]$List,

    [Parameter(Position = 0)]
    [string]$HostPath = '',

    [Parameter(Position = 1)]
    [string]$WslMountPath = ''
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\common.ps1"

# ─── List mode ──────────────────────────────────────────────────────────────

if ($List) {
    $status = Get-PaiDistroStatus
    if ($status -eq 'NotFound') {
        Fail "Distro '$DistroName' not found. Run install.ps1 first."
        exit 1
    }

    Write-Host ""
    Write-Host "Shared folders for $DistroName (symlinks in /home/claude/):" -ForegroundColor White
    Write-Host ""

    # List symlinks in /home/claude/ that point to /mnt/
    $output = wsl.exe -d $DistroName -- bash -lc "find /home/claude -maxdepth 1 -type l -exec sh -c 'target=\$(readlink \"\$1\"); case \"\$target\" in /mnt/*) printf \"  %-30s -> %s\n\" \"\$1\" \"\$target\" ;; esac' _ {} \;" 2>&1

    $found = $false
    foreach ($line in $output) {
        $lineStr = "$line"
        if ($lineStr.Trim()) {
            Write-Host $lineStr
            $found = $true
        }
    }

    if (-not $found) {
        Write-Host "  (no symlinks to Windows paths found)"
    }

    Write-Host ""
    exit 0
}

# ─── Validate arguments ────────────────────────────────────────────────────

if (-not $HostPath) {
    Write-Host ""
    Write-Host "Usage: .\scripts\mount.ps1 [options] <WindowsPath> [WslPath]"
    Write-Host ""
    Write-Host "  WindowsPath   Directory on Windows to share (must exist)"
    Write-Host "  WslPath       Where it appears in WSL (default: /home/claude/<dirname>)"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -List         Show current symlinks to Windows paths"
    Write-Host "  -Name X       Target a named instance (default: pai)"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\scripts\mount.ps1 C:\Projects\my-repo"
    Write-Host "  .\scripts\mount.ps1 C:\Projects\my-repo /home/claude/code"
    Write-Host "  .\scripts\mount.ps1 -List"
    exit 1
}

# Resolve and validate the host path
if (-not (Test-Path $HostPath -PathType Container)) {
    Fail "Directory not found: $HostPath"
    exit 1
}

$resolvedPath = (Resolve-Path $HostPath).Path

# Convert to WSL path: C:\foo\bar -> /mnt/c/foo/bar
$wslSourcePath = ConvertTo-WslPath $resolvedPath

# Default WSL mount path: /home/claude/<dirname>
if (-not $WslMountPath) {
    $dirName = Split-Path -Leaf $resolvedPath
    $WslMountPath = "/home/claude/$dirName"
}

# Check distro exists
$status = Get-PaiDistroStatus
if ($status -eq 'NotFound') {
    Fail "Distro '$DistroName' not found. Run install.ps1 first."
    exit 1
}

# Start distro if needed
if ($status -ne 'Running') {
    Write-Host "Starting distro..."
    wsl.exe -d $DistroName -- echo 'started' | Out-Null
    Start-Sleep -Seconds 1
}

# Check if symlink already exists
$existingTarget = wsl.exe -d $DistroName -- bash -lc "readlink '$WslMountPath' 2>/dev/null || echo ''" 2>&1
$existingTarget = "$existingTarget".Trim()
if ($existingTarget -eq $wslSourcePath) {
    Warn "Already mounted: $WslMountPath -> $wslSourcePath"
    exit 0
}

# ─── Create symlink ────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Mounting directory into $DistroName :" -ForegroundColor White
Write-Host ""
Write-Host "  Windows: $resolvedPath"
Write-Host "  WSL:     $WslMountPath"
Write-Host ""

# If there's an existing symlink pointing elsewhere, remove it
if ($existingTarget) {
    Write-Host "  Removing existing symlink ($existingTarget)..."
    wsl.exe -d $DistroName -- bash -lc "rm -f '$WslMountPath'" 2>$null
}

# Create the symlink
wsl.exe -d $DistroName -- bash -lc "ln -sf '$wslSourcePath' '$WslMountPath'"

if ($LASTEXITCODE -eq 0) {
    Ok "Symlink created"
}
else {
    Fail "Failed to create symlink"
    exit 1
}

Write-Host ""
Write-Host "Done! Your directory is now available in WSL at:" -ForegroundColor Green
Write-Host ""
Write-Host "  $WslMountPath"
Write-Host ""
Write-Host "  No restart needed — changes are immediate."
Write-Host "  Any changes on Windows are instantly visible in WSL, and vice versa."
Write-Host ""
