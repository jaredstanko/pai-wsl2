# PAI-WSL2 — Dynamic Folder Sharing
# Adds an fstab entry to mount a Windows directory into the distro.
# Requires a distro restart (~2 seconds) to apply the mount.
#
# Usage:
#   .\scripts\mount.ps1 C:\Projects\my-repo                    # Mount as ~/my-repo
#   .\scripts\mount.ps1 C:\Projects\my-repo /home/claude/code  # Mount at specific path
#   .\scripts\mount.ps1 -List                                  # Show current mounts
#   .\scripts\mount.ps1 -Name v2 C:\Projects\my-repo           # Target named instance
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

# Check if already in fstab
$fstabCheck = wsl.exe -d $DistroName -u root -- bash -c "grep -q '$resolvedPath' /etc/fstab 2>/dev/null && echo YES || echo NO" 2>&1
if ("$fstabCheck".Trim() -eq 'YES') {
    Warn "Already mounted: $resolvedPath -> $WslMountPath"
    exit 0
}

# ─── Add fstab entry and restart ──────────────────────────────────────────

Write-Host ""
Write-Host "Mounting directory into $DistroName :" -ForegroundColor White
Write-Host ""
Write-Host "  Windows: $resolvedPath"
Write-Host "  WSL:     $WslMountPath"
Write-Host ""

# Create mount point inside distro
wsl.exe -d $DistroName -u root -- bash -c "mkdir -p '$WslMountPath'" 2>$null

# Add fstab entry (encode spaces as \040 since fstab uses space as field delimiter)
$fstabResolvedPath = $resolvedPath -replace ' ', '\040'
$fstabLine = "$fstabResolvedPath $WslMountPath drvfs defaults,metadata,uid=1000,gid=1000 0 0"
wsl.exe -d $DistroName -u root -- bash -c "echo '$fstabLine' >> /etc/fstab"

if ($LASTEXITCODE -ne 0) {
    Fail "Failed to add fstab entry"
    exit 1
}
Ok "fstab entry added"

# Restart distro to apply mount
Write-Host "  Restarting distro to apply mount..."
wsl.exe --terminate $DistroName 2>&1 | Out-Null
Start-Sleep -Seconds 2
wsl.exe -d $DistroName -- echo 'restarted' 2>&1 | Out-Null
Ok "Distro restarted"

Write-Host ""
Write-Host "Done! Your directory is now available in WSL at:" -ForegroundColor Green
Write-Host ""
Write-Host "  $WslMountPath"
Write-Host ""
Write-Host "  Changes on Windows are visible in WSL, and vice versa."
Write-Host ""
