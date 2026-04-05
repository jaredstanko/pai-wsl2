#Requires -Version 5.1
<#
.SYNOPSIS
    PAI-WSL2 Installer — Deterministic WSL2 sandbox for Claude Code on Windows.

.DESCRIPTION
    Creates a dedicated WSL2 distro from an Ubuntu rootfs tarball, configures it
    with a 'claude' user, sets up hybrid NTFS/ext4 workspace directories, and
    provisions the sandbox with Claude Code, Bun, Node, and PAI tooling.

    This script is idempotent — safe to re-run if interrupted.

.PARAMETER Name
    Instance suffix for parallel installs. Default creates distro "pai" with
    workspace at C:\pai-workspace. With -Name "v2", creates "pai-v2" with
    workspace at C:\pai-workspace-v2.

.PARAMETER Port
    Portal port number. Defaults to 8080.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1
    powershell -ExecutionPolicy Bypass -File install.ps1 -Name v2 -Port 8082

.NOTES
    Requirements:
      - Windows 10 version 2004+ or Windows 11
      - WSL2 enabled (wsl --install will be offered if not)
      - Internet connection for downloads
      - PowerShell 5.1 (ships with Windows 10/11)
#>

param(
    [string]$Name = "",
    [int]$Port = 8080
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Instance naming ─────────────────────────────────────────────────────────

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

if ($Name -ne "") {
    $DistroName   = "pai-$Name"
    $WorkspaceDir = "C:\pai-workspace-$Name"
    $InstanceLabel = "PAI ($Name)"
} else {
    $DistroName   = "pai"
    $WorkspaceDir = "C:\pai-workspace"
    $InstanceLabel = "PAI"
}

$DistroDir    = "$env:LOCALAPPDATA\PAI\$DistroName"
$PortalPort   = $Port
$LogFile      = Join-Path $ScriptDir "pai-install-$(Get-Date -Format 'yyyyMMddTHHmmss').log"

# ─── Constants ──────────────────────────────────────────────────────────────

# Ubuntu Noble (24.04) WSL rootfs — "current" always points to the latest point release
$UbuntuRootfsUrl = "https://cloud-images.ubuntu.com/wsl/noble/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz"

# ─── Output helpers ──────────────────────────────────────────────────────────

$script:Step = 0
$TotalSteps  = 8

function Write-Step {
    param([string]$Message)
    $script:Step++
    Write-Host ""
    Write-Host "[$script:Step/$TotalSteps] " -ForegroundColor Cyan -NoNewline
    Write-Host $Message -ForegroundColor White
}

function Write-Ok {
    param([string]$Message)
    Write-Host "        " -NoNewline
    Write-Host "[OK] " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Skip {
    param([string]$Message)
    Write-Host "        " -NoNewline
    Write-Host "[SKIP] " -ForegroundColor Yellow -NoNewline
    Write-Host "$Message (already done)"
}

function Write-Fail {
    param([string]$Message, [string]$Hint = "")
    Write-Host "        " -NoNewline
    Write-Host "[FAIL] " -ForegroundColor Red -NoNewline
    Write-Host $Message
    if ($Hint -ne "") {
        Write-Host "        -> $Hint" -ForegroundColor Yellow
    }
    exit 1
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "[$timestamp] $Message"
}

# Retry helper for network operations — 3 attempts, exponential backoff.
function Invoke-WithRetry {
    param(
        [scriptblock]$Action,
        [string]$Description = "operation",
        [int]$MaxAttempts = 3
    )
    $delay = 5
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            & $Action
            return
        }
        catch {
            Write-Log "$Description attempt $attempt failed: $_"
            if ($attempt -lt $MaxAttempts) {
                Write-Host "        " -NoNewline
                Write-Host "[RETRY] " -ForegroundColor Yellow -NoNewline
                Write-Host "Attempt $attempt/$MaxAttempts failed. Retrying in ${delay}s..."
                Start-Sleep -Seconds $delay
                $delay = $delay * 2
            }
            else {
                throw $_
            }
        }
    }
}

# Run a command inside the WSL2 distro as root.
function Invoke-WslCommand {
    param([string]$Command)
    $result = wsl.exe -d $DistroName -- bash -c $Command 2>&1
    Write-Log "WSL ($DistroName): $Command -> $result"
    return $result
}

# Run a command inside the WSL2 distro as the claude user.
function Invoke-WslAsUser {
    param([string]$Command)
    $result = wsl.exe -d $DistroName -u claude -- bash -c $Command 2>&1
    Write-Log "WSL claude@$DistroName : $Command -> $result"
    return $result
}

# ─── Banner ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Sandbox My AI - PAI-WSL2 Installer" -ForegroundColor White
if ($Name -ne "") {
    Write-Host "  Instance: " -ForegroundColor White -NoNewline
    Write-Host $DistroName -ForegroundColor Cyan
}
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This will set up a sandboxed AI workspace on your PC."
Write-Host "  Estimated time: 5-10 minutes (first run)."
Write-Host ""
Write-Host "  Distro name:  $DistroName"
Write-Host "  Workspace:    $WorkspaceDir"
Write-Host "  Portal port:  $PortalPort"
Write-Host "  Log:          $LogFile"
Write-Host ""

Write-Log "=== PAI-WSL2 Install ($DistroName) started ==="

# ═════════════════════════════════════════════════════════════════════════════
# Step 1: Check system requirements
# ═════════════════════════════════════════════════════════════════════════════

Write-Step "Checking system requirements..."

# Windows version check — need Windows 10 build 19041+ or Windows 11
$osVersion = [System.Environment]::OSVersion.Version
$buildNumber = $osVersion.Build
if ($buildNumber -lt 19041) {
    Write-Fail "Windows 10 version 2004 (build 19041) or later is required." `
               "Current build: $buildNumber. Please update Windows."
}
$winVer = (Get-CimInstance Win32_OperatingSystem).Caption
Write-Ok "$winVer (build $buildNumber)"

# Check WSL2 is available
$wslPath = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wslPath) {
    Write-Fail "WSL is not installed." `
               "Run 'wsl --install' from an elevated PowerShell and reboot."
}

# Check WSL version (need WSL2, not WSL1)
$wslStatus = wsl.exe --status 2>&1 | Out-String
if ($wslStatus -match "Default Version:\s*2" -or $wslStatus -match "WSL 2") {
    Write-Ok "WSL2 is available"
} else {
    # Try setting default version to 2
    Write-Host "        Setting WSL default version to 2..." -ForegroundColor Yellow
    wsl.exe --set-default-version 2 2>&1 | Out-Null
    Write-Ok "WSL2 default version set"
}

# Check for WSLg — ships with Windows 11 only. Provides automatic PulseAudio
# (audio passthrough) and Wayland/X11 (GUI apps like Playwright browsers).
# Windows 10 does NOT have WSLg; audio falls back to PowerShell passthrough.
$hasWSLg = $false
if ($buildNumber -ge 22000) {
    $hasWSLg = $true
    Write-Ok "WSLg available (Windows 11 — native audio and GUI passthrough)"
} else {
    Write-Host "        " -NoNewline
    Write-Host "[INFO] " -ForegroundColor Yellow -NoNewline
    Write-Host "WSLg not available (requires Windows 11)."
    Write-Host "        Audio will use PowerShell passthrough (writes to C:\temp\pai-audio\)."
    Write-Host "        GUI apps (Playwright browser) will not display. All text features work fully."
}

# ═════════════════════════════════════════════════════════════════════════════
# Step 2: Check/install host tools
# ═════════════════════════════════════════════════════════════════════════════

Write-Step "Checking host tools..."

# Windows Terminal — check if installed, offer to install via winget
$wtInstalled = $false
$wtPackage = Get-AppxPackage -Name "Microsoft.WindowsTerminal" -ErrorAction SilentlyContinue
if ($wtPackage) {
    $wtInstalled = $true
    Write-Skip "Windows Terminal ($($wtPackage.Version))"
} else {
    $wingetPath = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($wingetPath) {
        Write-Host "        Installing Windows Terminal via winget..."
        try {
            Invoke-WithRetry -Description "Windows Terminal install" -Action {
                $output = winget install --id Microsoft.WindowsTerminal --accept-source-agreements --accept-package-agreements 2>&1
                Write-Log "winget install Windows Terminal: $output"
            }
            $wtInstalled = $true
            Write-Ok "Windows Terminal installed"
        }
        catch {
            Write-Host "        " -NoNewline
            Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline
            Write-Host "Could not install Windows Terminal. Install it manually from the Microsoft Store."
        }
    } else {
        Write-Host "        " -NoNewline
        Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline
        Write-Host "winget not found. Install Windows Terminal manually from the Microsoft Store."
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# Step 3: Create .wslconfig if not present
# ═════════════════════════════════════════════════════════════════════════════

Write-Step "Configuring WSL2 resource limits..."

$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
if (Test-Path $wslConfigPath) {
    Write-Skip ".wslconfig exists at $wslConfigPath"

    # Detect networking mode for later use
    $wslConfigContent = Get-Content $wslConfigPath -Raw
    if ($wslConfigContent -match "networkingMode\s*=\s*mirrored") {
        $script:NetworkMode = "mirrored"
        Write-Ok "Networking mode: mirrored (host IP stack shared)"
    } else {
        $script:NetworkMode = "NAT"
        Write-Ok "Networking mode: NAT (default)"
    }
} else {
    $templatePath = Join-Path $ScriptDir "config\.wslconfig"
    if (Test-Path $templatePath) {
        Copy-Item $templatePath $wslConfigPath
        Write-Ok ".wslconfig installed (4GB memory, 1GB swap, 4 CPUs)"
    } else {
        # Write a minimal config inline as fallback
        @"
[wsl2]
memory=4GB
swap=1GB
processors=4
localhostForwarding=true
"@ | Set-Content -Path $wslConfigPath -Encoding UTF8
        Write-Ok ".wslconfig created with defaults (4GB memory, 1GB swap)"
    }
    $script:NetworkMode = "NAT"
}

# ═════════════════════════════════════════════════════════════════════════════
# Step 4: Download Ubuntu rootfs and import WSL2 distro
# ═════════════════════════════════════════════════════════════════════════════

Write-Step "Creating WSL2 distro '$DistroName'..."

# Check if distro already exists
$existingDistros = wsl.exe --list --quiet 2>&1 | Out-String
# Normalize whitespace/encoding from wsl.exe output (UTF-16LE)
$existingDistros = $existingDistros -replace "`0", ""

if ($existingDistros -match "(?m)^\s*$([regex]::Escape($DistroName))\s*$") {
    Write-Skip "Distro '$DistroName' already exists"
} else {
    # Ensure distro directory exists
    if (-not (Test-Path $DistroDir)) {
        New-Item -ItemType Directory -Path $DistroDir -Force | Out-Null
    }

    # Download rootfs tarball
    $tarballUrl  = $UbuntuRootfsUrl
    $tarballPath = Join-Path $env:TEMP "ubuntu-noble-wsl.rootfs.tar.gz"

    if (Test-Path $tarballPath) {
        Write-Ok "Rootfs tarball already downloaded"
    } else {
        Write-Host "        Downloading Ubuntu Noble rootfs..."
        Invoke-WithRetry -Description "rootfs download" -Action {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $progressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $tarballUrl -OutFile $tarballPath -UseBasicParsing
        }
        Write-Ok "Rootfs downloaded ($('{0:N1}' -f ((Get-Item $tarballPath).Length / 1MB)) MB)"
    }

    # Import as WSL2 distro
    Write-Host "        Importing distro (this may take 1-2 minutes)..."
    $importOutput = wsl.exe --import $DistroName $DistroDir $tarballPath --version 2 2>&1
    Write-Log "wsl --import: $importOutput"
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "WSL import failed." "Check log: $LogFile"
    }
    Write-Ok "Distro '$DistroName' imported to $DistroDir"

    # Clean up tarball
    Remove-Item $tarballPath -Force -ErrorAction SilentlyContinue
}

# ═════════════════════════════════════════════════════════════════════════════
# Step 5: Configure distro (user, wsl.conf, restart)
# ═════════════════════════════════════════════════════════════════════════════

Write-Step "Configuring distro..."

# Copy wsl.conf into the distro
$wslConfSource = Join-Path $ScriptDir "config\wsl.conf"
$wslConfWslPath = "\\wsl$\$DistroName\etc\wsl.conf"

# First, make sure the distro is running
wsl.exe -d $DistroName -- echo "alive" 2>&1 | Out-Null

if (Test-Path $wslConfSource) {
    # Use wsl.exe to copy the file in, since \\wsl$ paths can be flaky
    $wslConfContent = Get-Content $wslConfSource -Raw
    $escapedContent = $wslConfContent -replace "'", "'\''"
    Invoke-WslCommand "echo '$escapedContent' > /etc/wsl.conf"
    Write-Ok "wsl.conf installed"
} else {
    Write-Fail "config/wsl.conf not found at $wslConfSource"
}

# Create claude user if it doesn't exist
$userCheck = Invoke-WslCommand "id claude 2>/dev/null && echo EXISTS || echo MISSING"
if ($userCheck -match "EXISTS") {
    Write-Skip "User 'claude' exists"
} else {
    Invoke-WslCommand "useradd -m -s /bin/bash claude"
    Invoke-WslCommand "echo 'claude ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/claude"
    Invoke-WslCommand "chmod 440 /etc/sudoers.d/claude"
    Write-Ok "User 'claude' created with sudo access"
}

# Terminate and restart the distro to apply wsl.conf (sets default user, enables systemd)
Write-Host "        Restarting distro to apply configuration..."
wsl.exe --terminate $DistroName 2>&1 | Out-Null
Start-Sleep -Seconds 2
# Trigger restart by running a command
wsl.exe -d $DistroName -- echo "restarted" 2>&1 | Out-Null
Write-Ok "Distro restarted with new configuration"

# ═════════════════════════════════════════════════════════════════════════════
# Step 6: Create workspace directories on Windows side
# ═════════════════════════════════════════════════════════════════════════════

Write-Step "Creating workspace directories..."

# Hybrid filesystem layout:
# - claude-home lives on ext4 inside WSL2 (/home/claude) for performance
# - User-facing dirs live on NTFS for Windows Explorer access
$ntfsDirs = @("data", "exchange", "portal", "work", "upstream")

if (-not (Test-Path $WorkspaceDir)) {
    New-Item -ItemType Directory -Path $WorkspaceDir -Force | Out-Null
}

foreach ($dir in $ntfsDirs) {
    $dirPath = Join-Path $WorkspaceDir $dir
    if (-not (Test-Path $dirPath)) {
        New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
    }
}
Write-Ok "$WorkspaceDir\ with $($ntfsDirs.Count) subdirectories"

# Create symlinks inside WSL2 pointing to the NTFS directories.
# The NTFS workspace is auto-mounted at /mnt/c/pai-workspace by WSL2.
$wslWorkspace = "/mnt/c/pai-workspace"
if ($Name -ne "") {
    $wslWorkspace = "/mnt/c/pai-workspace-$Name"
}

foreach ($dir in $ntfsDirs) {
    Invoke-WslAsUser "if [ ! -L ~/`$dir ] && [ ! -d ~/`$dir ]; then ln -s $wslWorkspace/$dir ~/$dir; fi"
}
Write-Ok "Symlinks created in /home/claude -> $wslWorkspace/*"

# ═════════════════════════════════════════════════════════════════════════════
# Step 7: Run provision.sh inside WSL2
# ═════════════════════════════════════════════════════════════════════════════

Write-Step "Provisioning sandbox (installs Claude Code, Bun, Node, tools)..."
Write-Host "        This step takes 3-5 minutes on first run."

$provisionScript = Join-Path $ScriptDir "scripts\provision.sh"
if (Test-Path $provisionScript) {
    # Copy provision script into the distro
    $provisionContent = Get-Content $provisionScript -Raw
    # Write to a temp location as root, then run as claude
    $escapedProvision = $provisionContent -replace "'", "'\''"
    Invoke-WslCommand "cat > /tmp/provision.sh << 'PROVISION_EOF'
$provisionContent
PROVISION_EOF"
    Invoke-WslCommand "chmod +x /tmp/provision.sh"

    # Run provision as claude user
    Write-Host "        Running provision.sh..."
    $provisionOutput = wsl.exe -d $DistroName -u claude -- bash /tmp/provision.sh 2>&1
    $provisionOutput | ForEach-Object { Write-Log "provision: $_" }

    # Show last few meaningful lines to the user
    $lastLines = ($provisionOutput | Select-Object -Last 5) -join "`n"
    if ($lastLines -ne "") {
        Write-Host "        $lastLines" -ForegroundColor DarkGray
    }

    Write-Ok "Sandbox provisioned"
} else {
    Write-Host "        " -NoNewline
    Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline
    Write-Host "scripts/provision.sh not found. Skipping provisioning."
    Write-Host "        You can provision manually later by running provision.sh inside the distro."
}

# ═════════════════════════════════════════════════════════════════════════════
# Step 8: Final setup (shortcuts, Terminal profile, Defender, orientation)
# ═════════════════════════════════════════════════════════════════════════════

Write-Step "Final setup..."

# --- Desktop shortcut ---
$desktopPath = [Environment]::GetFolderPath("Desktop")
$shortcutPath = Join-Path $desktopPath "$InstanceLabel.lnk"

if (-not (Test-Path $shortcutPath)) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = "wsl.exe"
        $shortcut.Arguments = "-d $DistroName"
        $shortcut.Description = "Launch $InstanceLabel sandbox"
        $shortcut.WorkingDirectory = $WorkspaceDir
        $shortcut.Save()
        Write-Ok "Desktop shortcut created"
    }
    catch {
        Write-Host "        " -NoNewline
        Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline
        Write-Host "Could not create desktop shortcut: $_"
    }
} else {
    Write-Skip "Desktop shortcut"
}

# --- Portal URL shortcut on Desktop ---
$portalUrlSrc = Join-Path $ScriptDir "config\portal.url"
$portalUrlDst = Join-Path $desktopPath "PAI Portal.url"
if ((Test-Path $portalUrlSrc) -and -not (Test-Path $portalUrlDst)) {
    Copy-Item $portalUrlSrc $portalUrlDst
    Write-Ok "Portal shortcut added to Desktop"
}

# --- Windows Terminal profile advisory ---
if ($wtInstalled) {
    $terminalProfilePath = Join-Path $ScriptDir "config\windows-terminal.json"
    Write-Host ""
    Write-Host "        " -NoNewline
    Write-Host "[TIP] " -ForegroundColor Cyan -NoNewline
    Write-Host "Add the PAI profile to Windows Terminal:"
    Write-Host "        1. Open Windows Terminal Settings (Ctrl+,)"
    Write-Host "        2. Click 'Open JSON file' at bottom-left"
    Write-Host "        3. Add the contents of config\windows-terminal.json to the 'profiles.list' array"
    if ($Name -ne "") {
        Write-Host "        4. Change 'commandline' to: wsl.exe -d $DistroName"
    }
    Write-Host ""
}

# --- Windows Defender exclusion advisory ---
$isAdmin = $false
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
catch { }

if ($isAdmin) {
    Write-Host ""
    Write-Host "        " -NoNewline
    Write-Host "[OPTIONAL] " -ForegroundColor Cyan -NoNewline
    Write-Host "Windows Defender exclusion"
    Write-Host "        Adding exclusions can improve WSL2 filesystem performance."
    Write-Host "        Paths: $WorkspaceDir, $DistroDir"
    Write-Host ""

    $response = Read-Host "        Add Defender exclusions? (y/N)"
    if ($response -eq "y" -or $response -eq "Y") {
        try {
            Add-MpPreference -ExclusionPath $WorkspaceDir
            Add-MpPreference -ExclusionPath $DistroDir
            Write-Ok "Defender exclusions added"
        }
        catch {
            Write-Host "        " -NoNewline
            Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline
            Write-Host "Could not add exclusions: $_"
        }
    } else {
        Write-Host "        Skipped. You can add them later from an elevated PowerShell:"
        Write-Host "        Add-MpPreference -ExclusionPath '$WorkspaceDir'"
        Write-Host "        Add-MpPreference -ExclusionPath '$DistroDir'"
    }
} else {
    Write-Host ""
    Write-Host "        " -NoNewline
    Write-Host "[TIP] " -ForegroundColor Cyan -NoNewline
    Write-Host "For better WSL2 performance, add Defender exclusions (run as Admin):"
    Write-Host "        Add-MpPreference -ExclusionPath '$WorkspaceDir'"
    Write-Host "        Add-MpPreference -ExclusionPath '$DistroDir'"
}

# --- Networking mode info ---
Write-Host ""
if ($script:NetworkMode -eq "mirrored") {
    Write-Host "        " -NoNewline
    Write-Host "[NET] " -ForegroundColor Cyan -NoNewline
    Write-Host "Mirrored networking detected. Services in WSL2 are accessible at localhost."
} else {
    Write-Host "        " -NoNewline
    Write-Host "[NET] " -ForegroundColor Cyan -NoNewline
    Write-Host "NAT networking (default). localhostForwarding is enabled in .wslconfig."
}

# ─── Done ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host ""
Write-Host "=================================================" -ForegroundColor Green
Write-Host "  SETUP COMPLETE - READ THESE INSTRUCTIONS" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Your PAI sandbox is ready. Here's what to do next:"
Write-Host ""
Write-Host "  1. Launch the sandbox:" -ForegroundColor White
Write-Host "     wsl -d $DistroName" -ForegroundColor Cyan
Write-Host "     (or double-click the '$InstanceLabel' shortcut on your Desktop)"
Write-Host ""
Write-Host "  2. Inside the sandbox, start Claude Code:" -ForegroundColor White
Write-Host "     claude" -ForegroundColor Cyan
Write-Host ""
Write-Host "  3. Sign in with your Anthropic account" -ForegroundColor White
Write-Host "     It will open a browser for you to log in."
Write-Host "     When it asks if you trust /home/claude/.claude, say yes."
Write-Host ""
Write-Host "  4. Once signed in, paste this message into Claude Code:" -ForegroundColor White
Write-Host ""
Write-Host "     Install PAI Companion following ~/pai-companion/companion/INSTALL.md." -ForegroundColor Cyan
Write-Host "     Skip Docker (use Bun directly for the portal) and skip the voice" -ForegroundColor Cyan
Write-Host "     module. Keep ~/.vm-ip set to localhost and VM_IP=localhost in .env." -ForegroundColor Cyan
Write-Host "     After installation, verify the portal is running at localhost:$PortalPort" -ForegroundColor Cyan
Write-Host "     and verify the voice server can successfully generate and play audio" -ForegroundColor Cyan
Write-Host "     end-to-end. Set both to start on boot." -ForegroundColor Cyan
Write-Host ""
Write-Host "  Filesystem layout:" -ForegroundColor White
Write-Host "     /home/claude/          ext4 (fast, Linux-native)" -ForegroundColor DarkGray
Write-Host "     $WorkspaceDir\    NTFS (visible in Explorer)" -ForegroundColor DarkGray
Write-Host "       data\                Persistent data" -ForegroundColor DarkGray
Write-Host "       exchange\            File exchange with Windows" -ForegroundColor DarkGray
Write-Host "       portal\              Web portal content" -ForegroundColor DarkGray
Write-Host "       work\                Working projects" -ForegroundColor DarkGray
Write-Host "       upstream\            Upstream repos" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Useful commands:" -ForegroundColor White
Write-Host "     wsl -d $DistroName                    # Enter sandbox" -ForegroundColor DarkGray
Write-Host "     wsl -d $DistroName -- claude           # Direct to Claude" -ForegroundColor DarkGray
Write-Host "     wsl --terminate $DistroName            # Stop sandbox" -ForegroundColor DarkGray
Write-Host "     wsl --shutdown                        # Stop all WSL" -ForegroundColor DarkGray
Write-Host "     explorer.exe $WorkspaceDir  # Open workspace" -ForegroundColor DarkGray
Write-Host ""
if ($Name -ne "") {
    Write-Host "  This is instance '$Name'. Use -Name $Name with scripts to target it." -ForegroundColor Yellow
    Write-Host ""
}
Write-Host "  Install log: $LogFile" -ForegroundColor DarkGray
Write-Host ""
Write-Host "=================================================" -ForegroundColor Green
Write-Host ""
