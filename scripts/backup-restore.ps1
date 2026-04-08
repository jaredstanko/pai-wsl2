# PAI-WSL2 -- Backup and Restore
# Creates full backups of the WSL2 distro and workspace, and restores them.
#
# Backup includes:
#   - WSL2 distro exported as .tar file (wsl --export)
#   - Workspace directory (%USERPROFILE%\pai-workspace\) copied alongside
#
# Usage:
#   .\scripts\backup-restore.ps1 backup                  # Backup default instance
#   .\scripts\backup-restore.ps1 restore                 # Restore default instance
#   .\scripts\backup-restore.ps1 backup -Name v2         # Backup named instance
#   .\scripts\backup-restore.ps1 restore -Name v2        # Restore named instance
#
# PowerShell 5.1 compatible.

param(
    [Parameter(Position = 0)]
    [ValidateSet('backup', 'restore')]
    [string]$Action,

    [string]$Name = '',
    [int]$Port = 0,

    # Optional: override backup directory (default: .\backups\)
    [string]$BackupDir = ''
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\common.ps1"

# ─── Defaults ───────────────────────────────────────────────────────────────

if (-not $BackupDir) {
    $BackupDir = Join-Path (Split-Path -Parent $ScriptDir) 'backups'
}

if (-not $Action) {
    Write-Host ""
    Write-Host "Usage: .\scripts\backup-restore.ps1 <backup|restore> [-Name X]"
    Write-Host ""
    Write-Host "Subcommands:"
    Write-Host "  backup    Back up the WSL2 distro and workspace"
    Write-Host "  restore   Restore from a backup"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Name X   Target a named instance (default: pai)"
    Write-Host ""
    Write-Host "Backups are stored in: $BackupDir\"
    exit 1
}

# ─── Backup ─────────────────────────────────────────────────────────────────

function Do-Backup {
    $status = Get-PaiDistroStatus
    if ($status -eq 'NotFound') {
        Fail "Distro '$DistroName' not found. Nothing to back up."
        exit 1
    }

    $dateStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupName = "backup-$dateStamp-$DistroName"
    $destDir = Join-Path $BackupDir $backupName

    Write-Host ""
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host "  PAI-WSL2 -- Backup" -ForegroundColor White
    Write-Host "  Distro: $DistroName" -ForegroundColor Cyan
    Write-Host "  Destination: $destDir\" -ForegroundColor Cyan
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host ""

    # Terminate distro for a clean export
    $wasRunning = $false
    if ($status -eq 'Running') {
        Write-Host "Terminating distro for clean backup..."
        wsl.exe -t $DistroName 2>$null
        Start-Sleep -Seconds 3
        $wasRunning = $true
        Ok "Distro terminated"
    }

    # Create backup directory
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    # Export distro as .tar
    $tarFile = Join-Path $destDir "$DistroName.tar"
    Write-Host "Exporting distro to $tarFile (this may take a few minutes)..."
    wsl.exe --export $DistroName $tarFile

    if ($LASTEXITCODE -eq 0) {
        $tarSize = "{0:N1} MB" -f ((Get-Item $tarFile).Length / 1MB)
        Ok "Distro exported ($tarSize)"
    }
    else {
        Fail "Failed to export distro"
        exit 1
    }

    # Copy workspace
    if (Test-Path $Workspace -PathType Container) {
        Write-Host "Copying workspace $Workspace\..."
        $workspaceDest = Join-Path $destDir 'pai-workspace'
        Copy-Item -Path $Workspace -Destination $workspaceDest -Recurse -Force
        Ok "Workspace copied"
    }
    else {
        Warn "Workspace '$Workspace' not found -- skipping"
    }

    # Restart distro if it was running
    if ($wasRunning) {
        Write-Host "Restarting distro..."
        wsl.exe -d $DistroName -- echo 'restarted' | Out-Null
        Ok "Distro restarted"
    }

    Write-Host ""
    Ok "Backup complete: $destDir\"
    Write-Host ""
}

# ─── Restore ────────────────────────────────────────────────────────────────

function Do-Restore {
    Write-Host ""
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host "  PAI-WSL2 -- Restore" -ForegroundColor White
    Write-Host "  Target distro: $DistroName" -ForegroundColor Cyan
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host ""

    # Find available backups
    if (-not (Test-Path $BackupDir -PathType Container)) {
        Fail "No backup directory found at $BackupDir\"
        exit 1
    }

    $backups = Get-ChildItem -Path $BackupDir -Directory -Filter "backup-*-$DistroName" | Sort-Object Name
    if ($backups.Count -eq 0) {
        Fail "No backups found for distro '$DistroName' in $BackupDir\"
        exit 1
    }

    # Let user pick a backup
    Write-Host "Available backups for '$DistroName':"
    Write-Host ""
    $i = 1
    foreach ($backup in $backups) {
        $tarFile = Join-Path $backup.FullName "$DistroName.tar"
        $size = "N/A"
        if (Test-Path $tarFile) {
            $size = "{0:N1} MB" -f ((Get-Item $tarFile).Length / 1MB)
        }
        Write-Host "  $i) $($backup.Name)  [$size]"
        $i++
    }
    Write-Host ""

    $choice = Read-Host "Select backup number"
    $choiceInt = 0
    if (-not [int]::TryParse($choice, [ref]$choiceInt) -or $choiceInt -lt 1 -or $choiceInt -gt $backups.Count) {
        Write-Host "Invalid selection." -ForegroundColor Red
        exit 1
    }

    $selectedBackup = $backups[$choiceInt - 1]
    $tarFile = Join-Path $selectedBackup.FullName "$DistroName.tar"

    if (-not (Test-Path $tarFile)) {
        Fail "Backup tar file not found: $tarFile"
        exit 1
    }

    # Check if distro already exists
    $status = Get-PaiDistroStatus
    if ($status -ne 'NotFound') {
        Write-Host ""
        Write-Host "WARNING: Distro '$DistroName' already exists!" -ForegroundColor Red
        $confirm = Read-Host "Unregister existing distro and replace it? [y/N]"
        if ($confirm -ne 'y' -and $confirm -ne 'Y') {
            Write-Host "Restore cancelled."
            exit 0
        }

        # Terminate and unregister
        if ($status -eq 'Running') {
            wsl.exe -t $DistroName 2>$null
            Start-Sleep -Seconds 2
        }
        wsl.exe --unregister $DistroName 2>$null
        Ok "Existing distro unregistered"
    }

    # Import the distro
    # Default install location: %LOCALAPPDATA%\PAI\<distro-name>\
    $installDir = Join-Path $env:LOCALAPPDATA "PAI\$DistroName"
    if (-not (Test-Path $installDir)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    }

    Write-Host "Importing distro from backup (this may take a few minutes)..."
    wsl.exe --import $DistroName $installDir $tarFile --version 2

    if ($LASTEXITCODE -eq 0) {
        Ok "Distro imported successfully"
    }
    else {
        Fail "Failed to import distro"
        exit 1
    }

    # Restore workspace
    $workspaceBackup = Join-Path $selectedBackup.FullName 'pai-workspace'
    if (Test-Path $workspaceBackup -PathType Container) {
        if (Test-Path $Workspace -PathType Container) {
            Write-Host ""
            Write-Host "WARNING: Workspace '$Workspace' already exists!" -ForegroundColor Yellow
            $confirm = Read-Host "Overwrite existing workspace? [y/N]"
            if ($confirm -eq 'y' -or $confirm -eq 'Y') {
                Remove-Item -Path $Workspace -Recurse -Force
                Copy-Item -Path $workspaceBackup -Destination $Workspace -Recurse -Force
                Ok "Workspace restored"
            }
            else {
                Warn "Workspace not restored -- existing data kept"
            }
        }
        else {
            Copy-Item -Path $workspaceBackup -Destination $Workspace -Recurse -Force
            Ok "Workspace restored"
        }
    }
    else {
        Warn "No workspace data in this backup -- skipping"
    }

    Write-Host ""
    Ok "Restore complete. Start your distro with: wsl -d $DistroName"
    Write-Host ""
}

# ─── Entry point ────────────────────────────────────────────────────────────

switch ($Action) {
    'backup'  { Do-Backup }
    'restore' { Do-Restore }
}
