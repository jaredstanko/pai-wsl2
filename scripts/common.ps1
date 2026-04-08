# PAI-WSL2 -- Shared PowerShell helpers
# Source this file at the top of every script to get instance-aware variables.
#
# Parses -Name and -Port parameters and sets:
#   $DistroName    "pai" (default) or "pai-X"
#   $InstanceSuffix "" (default) or "-X"
#   $Workspace     "$env:USERPROFILE\pai-workspace" (default) or "...\pai-workspace-X"
#   $PortalPort    8080 (default) or specified/auto-assigned port
#   $LogFile       "$env:USERPROFILE\.pai-install.log" or per-instance variant
#
# Usage in scripts:
#   $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
#   . "$ScriptDir\common.ps1"
#
# PowerShell 5.1 compatible -- no ternary, no null-coalescing, no ?. operator.

# ─── Parameter parsing ──────────────────────────────────────────────────────
# Scripts that source this file should define $Name and $Port before sourcing,
# or pass them as script parameters. We check if they exist and default.

if (-not (Get-Variable -Name 'Name' -Scope 'Script' -ErrorAction SilentlyContinue)) {
    $Name = ''
}
if (-not (Get-Variable -Name 'Port' -Scope 'Script' -ErrorAction SilentlyContinue)) {
    $Port = 0
}

# ─── Derive instance variables ──────────────────────────────────────────────

if ($Name -and $Name -ne '') {
    $script:DistroName     = "pai-$Name"
    $script:InstanceSuffix = "-$Name"
    $script:Workspace      = "$env:USERPROFILE\pai-workspace-$Name"
    $script:LogFile        = "$env:USERPROFILE\.pai-install-$Name.log"

    # Port: use specified, or default to 8081 (auto-scan only at install time)
    if ($Port -gt 0) {
        $script:PortalPort = $Port
    }
    else {
        $script:PortalPort = 8081
    }
}
else {
    $script:DistroName     = 'pai'
    $script:InstanceSuffix = ''
    $script:Workspace      = "$env:USERPROFILE\pai-workspace"
    $script:LogFile        = "$env:USERPROFILE\.pai-install.log"

    if ($Port -gt 0) {
        $script:PortalPort = $Port
    }
    else {
        $script:PortalPort = 8080
    }
}

# ─── Color helpers ──────────────────────────────────────────────────────────
# Styled output functions matching PAI-LIMA convention.

function Step {
    param(
        [string]$Number,
        [string]$Message
    )
    Write-Host ""
    Write-Host "[$Number] " -ForegroundColor Cyan -NoNewline
    Write-Host "$Message" -ForegroundColor White
}

function Ok {
    param([string]$Message)
    Write-Host "        " -NoNewline
    Write-Host "[PASS] " -ForegroundColor Green -NoNewline
    Write-Host "$Message"
}

function Skip {
    param([string]$Message)
    Write-Host "        " -NoNewline
    Write-Host "[SKIP] " -ForegroundColor Yellow -NoNewline
    Write-Host "$Message (already up to date)"
}

function Fail {
    param([string]$Message)
    Write-Host "        " -NoNewline
    Write-Host "[FAIL] " -ForegroundColor Red -NoNewline
    Write-Host "$Message"
}

function Warn {
    param([string]$Message)
    Write-Host "        " -NoNewline
    Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline
    Write-Host "$Message"
}

# ─── Distro status helper ──────────────────────────────────────────────────
# Returns: "Running", "Stopped", or "NotFound"

function Get-PaiDistroStatus {
    $output = wsl.exe --list --verbose 2>&1
    if ($LASTEXITCODE -ne 0) {
        return 'NotFound'
    }

    # Parse wsl --list --verbose output
    # Format: "  NAME            STATE           VERSION"
    foreach ($line in $output) {
        $trimmed = "$line".Trim()
        # Remove leading * for default distro
        $trimmed = $trimmed -replace '^\*\s*', ''
        # Split on whitespace
        $parts = $trimmed -split '\s+'
        if ($parts.Count -ge 2 -and $parts[0] -eq $script:DistroName) {
            $state = $parts[1]
            if ($state -eq 'Running') { return 'Running' }
            if ($state -eq 'Stopped') { return 'Stopped' }
            return $state
        }
    }

    return 'NotFound'
}

# ─── Run command inside distro ──────────────────────────────────────────────
# Executes a bash command inside the WSL2 distro as the default user.
# Returns the stdout output. Sets $LASTEXITCODE.

function Invoke-InDistro {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command
    )
    $result = wsl.exe -d $script:DistroName -- bash -lc $Command 2>&1
    return $result
}

# ─── Convenience: ensure distro is running ──────────────────────────────────

function Start-PaiDistro {
    $status = Get-PaiDistroStatus
    if ($status -eq 'NotFound') {
        Write-Error "Distro '$script:DistroName' does not exist. Run install.ps1 first."
        exit 1
    }
    if ($status -ne 'Running') {
        Write-Host "Starting distro '$script:DistroName'..."
        # Start by running a trivial command -- WSL auto-starts the distro
        wsl.exe -d $script:DistroName -- echo 'started' | Out-Null
        Write-Host "Distro started." -ForegroundColor Green
    }
}

# ─── Path conversion helper ─────────────────────────────────────────────────
# Convert Windows path (C:\foo\bar) to WSL path (/mnt/c/foo/bar)

function ConvertTo-WslPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WindowsPath
    )
    $resolved = (Resolve-Path $WindowsPath -ErrorAction Stop).Path
    # C:\foo\bar -> /mnt/c/foo/bar
    $drive = $resolved.Substring(0, 1).ToLower()
    $rest = $resolved.Substring(2) -replace '\\', '/'
    return "/mnt/$drive$rest"
}
