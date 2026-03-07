# PAI WSL2 Setup Script (Windows PowerShell)
# Run this from an elevated (Administrator) PowerShell prompt.
#
# Usage:
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\setup-wsl.ps1
#
# This script:
#   1. Enables WSL2 and installs Ubuntu 24.04
#   2. Creates the shared workspace directory
#   3. Copies the install script into the workspace

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  PAI WSL2 Setup (Windows)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# -----------------------------------------------------------
# Step 1: Check for Administrator privileges
# -----------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[x] This script must be run as Administrator." -ForegroundColor Red
    Write-Host "    Right-click PowerShell -> Run as Administrator" -ForegroundColor Yellow
    exit 1
}

# -----------------------------------------------------------
# Step 2: Enable WSL2 features
# -----------------------------------------------------------
Write-Host "[+] Enabling WSL features..." -ForegroundColor Green

$wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux
if ($wslFeature.State -ne "Enabled") {
    dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
}

$vmFeature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
if ($vmFeature.State -ne "Enabled") {
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
    Write-Host ""
    Write-Host "[!] VirtualMachinePlatform was just enabled." -ForegroundColor Yellow
    Write-Host "    You MUST reboot before continuing." -ForegroundColor Yellow
    Write-Host "    After reboot, run this script again." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# Set WSL default version to 2
wsl --set-default-version 2

# -----------------------------------------------------------
# Step 3: Install Ubuntu 24.04
# -----------------------------------------------------------
Write-Host "[+] Checking for Ubuntu 24.04 installation..." -ForegroundColor Green

$installed = wsl -l -q 2>$null | Where-Object { $_ -match "Ubuntu-24.04" }
if ($installed) {
    Write-Host "[+] Ubuntu 24.04 is already installed." -ForegroundColor Green
} else {
    Write-Host "[+] Installing Ubuntu 24.04 (this may take a few minutes)..." -ForegroundColor Green
    wsl --install -d Ubuntu-24.04 --no-launch
    Write-Host ""
    Write-Host "[!] Ubuntu 24.04 installed." -ForegroundColor Yellow
    Write-Host "    On first launch you will be prompted to create a UNIX username and password." -ForegroundColor Yellow
    Write-Host "    Use 'claude' as the username to match the expected layout." -ForegroundColor Yellow
}

# -----------------------------------------------------------
# Step 4: Configure .wslconfig for performance
# -----------------------------------------------------------
$wslConfigPath = "$env:USERPROFILE\.wslconfig"
if (-not (Test-Path $wslConfigPath)) {
    Write-Host "[+] Creating .wslconfig with recommended settings..." -ForegroundColor Green
    @"
[wsl2]
memory=4GB
processors=4
swap=2GB

[experimental]
autoMemoryReclaim=gradual
sparseVhd=true
"@ | Set-Content -Path $wslConfigPath -Encoding UTF8
    Write-Host "[+] Created $wslConfigPath" -ForegroundColor Green
} else {
    Write-Host "[+] .wslconfig already exists, skipping." -ForegroundColor Green
}

# -----------------------------------------------------------
# Step 5: Create shared workspace
# -----------------------------------------------------------
$workspace = "$env:USERPROFILE\claude-workspace"
if (-not (Test-Path $workspace)) {
    New-Item -ItemType Directory -Path $workspace | Out-Null
    Write-Host "[+] Created shared workspace: $workspace" -ForegroundColor Green
} else {
    Write-Host "[+] Shared workspace already exists: $workspace" -ForegroundColor Green
}

# -----------------------------------------------------------
# Step 6: Copy install script to workspace
# -----------------------------------------------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$installSrc = Join-Path $scriptDir "install.sh"
if (Test-Path $installSrc) {
    Copy-Item -Path $installSrc -Destination "$workspace\install.sh" -Force
    Write-Host "[+] Copied install.sh to $workspace" -ForegroundColor Green
} else {
    Write-Host "[!] install.sh not found in script directory. Copy it manually to $workspace" -ForegroundColor Yellow
}

# -----------------------------------------------------------
# Done
# -----------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Windows Setup Complete" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "[+] Shared workspace: $workspace" -ForegroundColor Green
Write-Host "[+] Inside WSL2 this is: /mnt/c/Users/$env:USERNAME/claude-workspace" -ForegroundColor Green
Write-Host ""
Write-Host "[!] Next steps:" -ForegroundColor Yellow
Write-Host "    1. Launch Ubuntu 24.04 from Start Menu (first time: create user 'claude')" -ForegroundColor Yellow
Write-Host "    2. Inside WSL2, run:" -ForegroundColor Yellow
Write-Host "       bash /mnt/c/Users/$env:USERNAME/claude-workspace/install.sh" -ForegroundColor Yellow
Write-Host ""
