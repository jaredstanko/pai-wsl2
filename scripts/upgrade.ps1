# PAI-WSL2 — Upgrade existing installation
# Safe to run on an existing distro without losing data.
#
# What this upgrades:
#   - VM-side tools, aliases, and .bashrc environment (via provision.sh)
#   - Claude Code (migrates npm->native if needed, runs claude update)
#   - System packages (apt-get upgrade)
#
# What this does NOT touch:
#   - Your data in C:\pai-workspace\
#   - Your Claude Code authentication and sessions
#   - Your PAI configuration (~/.claude/ inside the distro)
#   - Your work\ directory
#
# Usage:
#   .\scripts\upgrade.ps1                    # Upgrade default instance
#   .\scripts\upgrade.ps1 -Name v2           # Upgrade named instance
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
Write-Host ("=" * 50) -ForegroundColor Cyan
Write-Host "  PAI-WSL2 — Upgrade" -ForegroundColor White
if ($InstanceSuffix) {
    Write-Host "  Instance: $DistroName" -ForegroundColor Cyan
}
Write-Host ("=" * 50) -ForegroundColor Cyan
Write-Host ""
Write-Host "  This upgrades your existing installation without losing data."
Write-Host "  Your workspace, config, and sessions are preserved."
Write-Host ""

# ─── Step 1: Check distro exists ───────────────────────────────────────────

Step "1/4" "Checking distro..."

$status = Get-PaiDistroStatus
if ($status -eq 'NotFound') {
    Fail "Distro '$DistroName' not found. Run install.ps1 for a fresh install."
    exit 1
}

if ($status -ne 'Running') {
    Write-Host "        Starting distro..."
    wsl.exe -d $DistroName -- echo 'started' | Out-Null
    Start-Sleep -Seconds 2
    Ok "Distro started"
}
else {
    Ok "Distro '$DistroName' is running"
}

# ─── Step 2: Ensure workspace directories exist ───────────────────────────

Step "2/4" "Checking workspace directories..."

$dirs = @('data', 'exchange', 'portal', 'work', 'upstream')
$created = 0

foreach ($dir in $dirs) {
    $dirPath = Join-Path $Workspace $dir
    if (-not (Test-Path $dirPath -PathType Container)) {
        New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
        $created++
    }
}

if ($created -gt 0) {
    Ok "Created $created missing directories in $Workspace\"
}
else {
    Skip "All directories exist"
}

# ─── Step 3: Re-run provision.sh inside the distro ────────────────────────

Step "3/4" "Updating distro tools and environment..."

# Copy latest provision.sh into the distro
$provisionScript = Join-Path $ScriptDir 'provision.sh'
if (-not (Test-Path $provisionScript)) {
    Fail "provision.sh not found at $provisionScript"
    exit 1
}

$wslScriptDir = ConvertTo-WslPath $ScriptDir
$ntfsWorkspace = ConvertTo-WslPath $Workspace

# Copy and run provision.sh
wsl.exe -d $DistroName -- bash -c "cp '$wslScriptDir/provision.sh' ~/provision.sh && chmod +x ~/provision.sh"
wsl.exe -d $DistroName -- bash -lc "NTFS_WORKSPACE='$ntfsWorkspace' bash ~/provision.sh"

if ($LASTEXITCODE -eq 0) {
    Ok "Provision script completed successfully"
}
else {
    Warn "Provision script completed with warnings — check output above"
}

# ─── Step 4: Upgrade Claude Code ──────────────────────────────────────────

Step "4/4" "Upgrading Claude Code..."

$claudeUpgrade = wsl.exe -d $DistroName -- bash -lc '
  CLAUDE_PATH=$(command -v claude 2>/dev/null || echo "")

  if [ -z "$CLAUDE_PATH" ]; then
    echo "[!] Claude Code not found -- installing native..."
    curl -fsSL https://claude.ai/install.sh | bash
  elif echo "$CLAUDE_PATH" | grep -qE "node_modules|npm|lib/node_modules"; then
    echo "[!] Claude Code installed via npm (old method): $CLAUDE_PATH"
    echo "[!] Removing npm version and installing native..."
    npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true
    bun remove -g @anthropic-ai/claude-code 2>/dev/null || true
    curl -fsSL https://claude.ai/install.sh | bash
  else
    echo "[=] Claude Code already native: $CLAUDE_PATH"
    echo "[+] Running claude update..."
    claude update 2>/dev/null || echo "[!] claude update not available -- already latest or manual update needed"
  fi
' 2>&1

foreach ($line in $claudeUpgrade) {
    Write-Host "        $line"
}

Ok "Claude Code up to date"

# ─── Done ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host ("=" * 50) -ForegroundColor Green
Write-Host "  Upgrade complete!" -ForegroundColor Green
Write-Host ("=" * 50) -ForegroundColor Green
Write-Host ""
Write-Host "  What was preserved:"
Write-Host "    - All files in $Workspace\"
Write-Host "    - Claude Code authentication"
Write-Host "    - PAI configuration (~/.claude/)"
Write-Host "    - Claude Code sessions"
Write-Host ""
Write-Host "  What was updated:"
Write-Host "    - System packages (apt-get upgrade)"
Write-Host "    - Shell environment (.bashrc, .zshrc)"
Write-Host "    - Claude Code"
Write-Host "    - Bun, Node.js, Playwright"
Write-Host "    - Portal URL: http://localhost:$PortalPort"
Write-Host ""
