#!/bin/bash
# PAI-WSL2 Provisioning Script -- Distro Setup
# Run this INSIDE the WSL2 distro as the 'claude' user.
# Called automatically by install.ps1 on the Windows host.
#
# This script is idempotent -- safe to re-run if interrupted.
#
# Usage:
#   bash ~/provision.sh

set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG_FILE="$HOME/.provision.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⊘${NC} $1"; }
err()  { echo -e "  ${RED}✗${NC} $1"; }
step() { echo -e "\n${CYAN}[$1]${NC} ${BOLD}$2${NC}"; }

# ─── Retry helper (3 attempts, exponential backoff) ─────────────────────────
retry() {
  local max_attempts=3
  local delay=5
  local attempt=1
  local cmd="$*"

  while [ $attempt -le $max_attempts ]; do
    if eval "$cmd"; then
      return 0
    fi
    if [ $attempt -lt $max_attempts ]; then
      warn "Attempt $attempt/$max_attempts failed. Retrying in ${delay}s..."
      sleep $delay
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done
  err "Failed after $max_attempts attempts: $cmd"
  return 1
}

# ─── Constants ──────────────────────────────────────────────────────────────
PAI_REPO="https://github.com/danielmiessler/PAI.git"
PAI_COMPANION_REPO="https://github.com/chriscantey/pai-companion.git"

# Workspace dirs are mounted at /home/claude/{data,exchange,...} via fstab

echo -e "${BOLD}"
echo "============================================"
echo "  PAI-WSL2 Provisioning"
echo "============================================"
echo -e "${NC}"

# ─── Step 1: System packages ───────────────────────────────────────────────
step "1/6" "Installing system packages..."

# Add NodeSource repo for Node.js 22 LTS before apt-get update (single update pass)
NODE_NEEDS_SETUP=false
if command -v node &>/dev/null && node --version 2>/dev/null | grep -q "^v2[2-9]"; then
  log "Node.js already installed: $(node --version)"
else
  NODE_NEEDS_SETUP=true
  log "Adding NodeSource repo for Node.js 22 LTS..."
  sudo mkdir -p /etc/apt/keyrings
  retry "curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg"
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list > /dev/null
fi

retry "sudo apt-get update -qq"

# Core packages -- same set as PAI-LIMA plus WSL-specific additions
# shellcheck disable=SC2086
retry "sudo apt-get install -y -qq \
  jq fzf ripgrep fd-find sqlite3 tmux bat ffmpeg curl wget imagemagick \
  nmap whois dnsutils net-tools traceroute mtr \
  texlive-latex-base texlive-fonts-recommended pandoc \
  golang-go python3 python3-pip python3-venv \
  build-essential git zip unzip tree htop \
  ca-certificates gnupg espeak-ng \
  pulseaudio-utils socat"
log "System packages installed"

if [ "$NODE_NEEDS_SETUP" = true ]; then
  retry "sudo apt-get install -y -qq nodejs"
  log "Node.js $(node --version) installed from NodeSource"
fi

# uv -- modern Python package runner
if command -v uv &>/dev/null; then
  log "uv already installed: $(uv --version 2>/dev/null || echo 'present')"
else
  retry "curl -LsSf https://astral.sh/uv/install.sh | sh"
  export PATH="$HOME/.local/bin:$PATH"
  log "uv installed: $(uv --version 2>/dev/null || echo 'installed')"
fi

# yt-dlp via uv tool
if command -v yt-dlp &>/dev/null; then
  log "yt-dlp already installed: $(yt-dlp --version 2>/dev/null || echo 'present')"
else
  uv tool install yt-dlp
  log "yt-dlp installed via uv: $(yt-dlp --version 2>/dev/null || echo 'installed')"
fi

# ─── Audio helper: play a file through WSLg or PowerShell fallback ───────────
# Shared function used by both 'say' and 'afplay' shims.
# Fallback chain:
#   1. WSLg PulseAudio (Windows 11) -- ffplay via /mnt/wslg/PulseServer
#   2. PowerShell passthrough (Windows 10) -- write to NTFS, play via Windows APIs
mkdir -p "$HOME/.local/bin"

cat > "$HOME/.local/bin/pai-play-audio" <<'PLAYSHIM'
#!/bin/bash
# pai-play-audio -- play an audio file through the best available path
# Usage: pai-play-audio <file.wav|file.mp3>
FILE="$1"
[ -z "$FILE" ] || [ ! -f "$FILE" ] && exit 1

# Try WSLg PulseAudio first (Windows 11)
if [ -e /mnt/wslg/PulseServer ]; then
  PULSE_SERVER=unix:/mnt/wslg/PulseServer ffplay -nodisp -autoexit -loglevel quiet "$FILE" 2>/dev/null
  exit $?
fi

# Fallback: PowerShell passthrough (Windows 10, requires interop opt-in)
# If interop is disabled (user chose full sandbox), audio silently fails.
if ! command -v powershell.exe >/dev/null 2>&1; then
  exit 1  # interop disabled -- no audio available, fail silently
fi

AUDIO_DIR="/mnt/pai-audio"
if [ ! -d "$AUDIO_DIR" ]; then
  exit 1  # audio mount not configured -- user declined audio during install
fi

BASENAME=$(basename "$FILE")
cp "$FILE" "$AUDIO_DIR/$BASENAME" 2>/dev/null || exit 1
WIN_PATH="C:\\temp\\pai-audio\\$BASENAME"

case "${FILE##*.}" in
  wav)
    powershell.exe -NoProfile -Command "(New-Object Media.SoundPlayer '$WIN_PATH').PlaySync()" 2>/dev/null
    ;;
  mp3|ogg|m4a|*)
    # MediaPlayer handles MP3 and most formats
    powershell.exe -NoProfile -Command "Add-Type -AssemblyName PresentationCore; \$p = New-Object System.Windows.Media.MediaPlayer; \$p.Open([Uri]'$WIN_PATH'); \$p.Play(); Start-Sleep -Milliseconds 500; while (\$p.Position -lt \$p.NaturalDuration.TimeSpan) { Start-Sleep -Milliseconds 200 }; \$p.Close()" 2>/dev/null
    ;;
esac

# Clean up temp file
rm -f "$AUDIO_DIR/$BASENAME" 2>/dev/null
PLAYSHIM
chmod +x "$HOME/.local/bin/pai-play-audio"
log "pai-play-audio helper installed (WSLg -> PowerShell fallback)"

# ─── Install 'say' shim ─────────────────────────────────────────────────────
cat > "$HOME/.local/bin/say" <<'SAYSHIM'
#!/bin/bash
# say -- Linux shim for macOS 'say' command
# Fallback chain: Kokoro TTS -> espeak-ng via pai-play-audio
TEXT="$*"
[ -z "$TEXT" ] && exit 0

# Try Kokoro TTS if running
if curl -sf http://localhost:7880/health >/dev/null 2>&1; then
  TMPFILE=$(mktemp /tmp/say-XXXXXX.mp3)
  if curl -s -X POST http://localhost:7880/tts \
    -H "Content-Type: application/json" \
    -d "{\"text\": \"$TEXT\"}" -o "$TMPFILE" 2>/dev/null && [ -s "$TMPFILE" ]; then
    pai-play-audio "$TMPFILE"
    rm -f "$TMPFILE"
    exit 0
  fi
  rm -f "$TMPFILE"
fi

# Fall back to espeak-ng
if command -v espeak-ng >/dev/null 2>&1; then
  # espeak-ng: try WSLg first, then generate WAV and play via PowerShell
  if [ -e /mnt/wslg/PulseServer ]; then
    PULSE_SERVER=unix:/mnt/wslg/PulseServer espeak-ng "$TEXT" 2>/dev/null
  else
    TMPFILE=$(mktemp /tmp/say-XXXXXX.wav)
    espeak-ng -w "$TMPFILE" "$TEXT" 2>/dev/null
    pai-play-audio "$TMPFILE"
    rm -f "$TMPFILE"
  fi
  exit 0
fi
SAYSHIM
chmod +x "$HOME/.local/bin/say"
log "Linux 'say' shim installed (Kokoro -> espeak-ng, WSLg/PowerShell audio)"

# ─── Install 'afplay' shim ──────────────────────────────────────────────────
cat > "$HOME/.local/bin/afplay" <<'AFSHIM'
#!/bin/bash
# afplay -- Linux shim for macOS afplay command
# Routes audio through pai-play-audio (WSLg or PowerShell fallback)
FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -v) shift 2 ;;  # volume flag ignored in passthrough mode
    -*) shift ;;
    *) FILE="$1"; shift ;;
  esac
done
[ -z "$FILE" ] || [ ! -f "$FILE" ] && exit 1
pai-play-audio "$FILE"
AFSHIM
chmod +x "$HOME/.local/bin/afplay"
log "Linux 'afplay' shim installed (via pai-play-audio)"

# ─── Step 2: Bun ───────────────────────────────────────────────────────────
step "2/6" "Installing Bun..."

if command -v bun &>/dev/null; then
  log "Bun already installed: $(bun --version)"
else
  retry "curl -fsSL https://bun.sh/install | bash"
  source ~/.bashrc 2>/dev/null || true
  log "Bun installed"
fi

# Ensure bun is on PATH for the rest of this script
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# ─── Step 3: Claude Code ───────────────────────────────────────────────────
step "3/6" "Installing Claude Code..."

# Detect and remove old npm-based installs
CLAUDE_NEEDS_INSTALL=false
if command -v claude &>/dev/null; then
  CLAUDE_PATH=$(command -v claude)
  if [[ "$CLAUDE_PATH" == *"node_modules"* ]] || [[ "$CLAUDE_PATH" == *"npm"* ]] || [[ "$CLAUDE_PATH" == *"lib/node_modules"* ]]; then
    warn "Removing old npm-based Claude Code install: $CLAUDE_PATH"
    npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true
    bun remove -g @anthropic-ai/claude-code 2>/dev/null || true
    CLAUDE_NEEDS_INSTALL=true
  else
    log "Claude Code already installed (native): $(claude --version 2>/dev/null || echo 'installed')"
  fi
else
  CLAUDE_NEEDS_INSTALL=true
fi

if [ "$CLAUDE_NEEDS_INSTALL" = true ]; then
  retry "curl -fsSL https://claude.ai/install.sh | bash"
  log "Claude Code installed"
fi

# Claude Code may install to ~/.claude/bin or ~/.local/bin
export PATH="$HOME/.claude/bin:$HOME/.local/bin:$PATH"

# Verify
if command -v claude &>/dev/null; then
  log "Claude Code verified: $(claude --version 2>/dev/null | grep -oE '[0-9.]+' | head -1 || echo 'present')"
else
  err "Claude Code not found after install"
  exit 1
fi

echo ""
warn "After setup completes, run 'claude' and sign in with your Anthropic account."
echo ""

# Disable telemetry and crash reporting
mkdir -p "$HOME/.claude"
SETTINGS_FILE="$HOME/.claude/settings.json"
if [ -f "$SETTINGS_FILE" ]; then
  # Merge env block into existing settings
  TMP_SETTINGS=$(mktemp)
  jq '. + {"env": ((.env // {}) + {"DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"})}' "$SETTINGS_FILE" > "$TMP_SETTINGS" && mv "$TMP_SETTINGS" "$SETTINGS_FILE"
else
  cat > "$SETTINGS_FILE" <<'SETTINGSEOF'
{
  "env": {
    "DISABLE_TELEMETRY": "1",
    "DISABLE_ERROR_REPORTING": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
SETTINGSEOF
fi
log "Claude Code telemetry and crash reporting disabled"

# ─── Step 3b: Shell environment ────────────────────────────────────────────
step "3b" "Configuring shell environment..."

SENTINEL="# --- PAI environment (managed by provision.sh) ---"
ENV_BLOCK='
# --- PAI environment (managed by provision.sh) ---

# Bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# Claude Code
export PATH="$HOME/.claude/bin:$PATH"

# Local binaries (pip --user, uv, etc.)
export PATH="$HOME/.local/bin:$PATH"

# Go
export PATH="$HOME/go/bin:$PATH"

# Node global (npm install -g)
export PATH="$HOME/.npm-global/bin:$PATH"

# WSLg PulseAudio (Windows 11 only) -- set only if socket exists
if [ -e /mnt/wslg/PulseServer ]; then
  export PULSE_SERVER=unix:/mnt/wslg/PulseServer
fi

# Default editor
export EDITOR=nano

# PAI launcher
alias pai='\''bun $HOME/.claude/PAI/Tools/pai.ts'\''

# --- end PAI environment ---
'

for rcfile in ~/.bashrc ~/.zshrc; do
  touch "$rcfile"
  if grep -qF "$SENTINEL" "$rcfile" 2>/dev/null; then
    sed -i "/$SENTINEL/,/# --- end PAI environment ---/d" "$rcfile"
  fi
  echo "$ENV_BLOCK" >> "$rcfile"
done
log "PAI environment block written to .bashrc and .zshrc"

# Configure npm global prefix
mkdir -p "$HOME/.npm-global"
if ! npm config get prefix 2>/dev/null | grep -q '.npm-global'; then
  npm config set prefix "$HOME/.npm-global"
  log "npm global prefix set to ~/.npm-global"
fi

export PATH="$HOME/.claude/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.npm-global/bin:$PATH"

# ─── Step 4: PAI ───────────────────────────────────────────────────────────
step "4/6" "Installing PAI..."

if [ -d "$HOME/.claude/PAI" ] || [ -d "$HOME/.claude/skills/PAI" ]; then
  log "PAI already installed. Skipping."
else
  log "Cloning PAI repo..."
  cd /tmp
  rm -rf PAI
  retry "git clone '${PAI_REPO}'"
  cd PAI

  LATEST_RELEASE=$(ls Releases/ | sort -V | tail -1)
  log "Using PAI release: $LATEST_RELEASE"
  cp -r "Releases/$LATEST_RELEASE/.claude/" ~/
  cd ~/.claude

  # Fix installer for CLI mode (no GUI in WSL)
  if [ -f install.sh ]; then
    sed -i 's/--mode gui/--mode cli/' install.sh
    bash install.sh
  fi

  # Fix shell config paths
  if [ -f ~/.zshrc ]; then
    cat ~/.zshrc >> ~/.bashrc
    sed -i 's|skills/PAI/Tools/pai.ts|PAI/Tools/pai.ts|g' ~/.bashrc
  fi

  rm -rf /tmp/PAI

  # Ensure PAI skill symlink exists
  if [ -d "$HOME/.claude/PAI" ] && [ ! -d "$HOME/.claude/skills/PAI" ]; then
    mkdir -p "$HOME/.claude/skills"
    ln -sf "$HOME/.claude/PAI" "$HOME/.claude/skills/PAI"
    log "Symlinked ~/.claude/PAI -> ~/.claude/skills/PAI"
  fi

  log "PAI installed"
fi

source ~/.bashrc 2>/dev/null || true

# ─── Step 4b: IP and .env ─────────────────────────────────────────────────
VM_IP="localhost"
echo "$VM_IP" > ~/.vm-ip
log "VM IP: $VM_IP (WSL2 port-forwards to host)"

if [ -d "$HOME/.claude" ] && touch "$HOME/.claude/.env-test" 2>/dev/null; then
  rm -f "$HOME/.claude/.env-test"
  if [ -f ~/.claude/.env ]; then
    sed -i '/^VM_IP=/d; /^PORTAL_PORT=/d' ~/.claude/.env
  fi
  cat >> ~/.claude/.env <<ENVEOF
VM_IP=$VM_IP
PORTAL_PORT=${PORTAL_PORT:-8080}
ENVEOF
  log "VM_IP and PORTAL_PORT written to ~/.claude/.env"

  # Pre-trust common workspaces so Claude Code doesn't prompt on first run
  CLAUDE_JSON="$HOME/.claude.json"
  if [ ! -f "$CLAUDE_JSON" ]; then
    cat > "$CLAUDE_JSON" <<TRUSTEOF
{
  "projects": {
    "$HOME/.claude": {
      "allowedTools": [],
      "hasTrustDialogAccepted": true
    },
    "$HOME": {
      "allowedTools": [],
      "hasTrustDialogAccepted": true
    }
  }
}
TRUSTEOF
    log "Claude Code workspaces pre-trusted"
  else
    log "Claude Code config already exists -- skipping trust setup"
  fi
else
  warn "$HOME/.claude mount not writable -- skipping .env write"
fi

# ─── Step 4c: Verify workspace mounts ────────────────────────────────────
step "4c" "Checking workspace mounts..."

# Workspace directories are mounted via /etc/fstab (configured by install.ps1).
# Automount of C:\ is disabled for sandbox isolation -- only these dirs are shared.
USER_DIRS="data exchange portal work upstream"

for dir in $USER_DIRS; do
  if [ -d "$HOME/$dir" ]; then
    log "~/$dir mounted"
  else
    warn "~/$dir not mounted -- fstab may need a distro restart"
  fi
done

# ─── Step 5: PAI Companion ────────────────────────────────────────────────
step "5/6" "Cloning PAI Companion..."

if [ -d "$HOME/pai-companion/companion" ]; then
  log "PAI Companion already cloned"
else
  cd /tmp
  rm -rf pai-companion
  if retry "git clone '${PAI_COMPANION_REPO}'"; then
    rm -rf "$HOME/pai-companion"
    cp -r /tmp/pai-companion "$HOME/pai-companion"
    rm -rf /tmp/pai-companion
    log "PAI Companion cloned to ~/pai-companion"
  else
    warn "Failed to clone pai-companion -- you can clone it manually later."
  fi
fi

# ─── Step 6: Playwright ───────────────────────────────────────────────────
step "6/6" "Installing Playwright..."

if command -v bun &>/dev/null; then
  cd /tmp
  mkdir -p playwright-setup && cd playwright-setup
  bun init -y 2>/dev/null || true
  bun add playwright 2>/dev/null || true
  retry "bunx playwright install --with-deps chromium" || warn "Playwright install may need manual completion."
  cd /tmp && rm -rf playwright-setup
  log "Playwright installed"
else
  warn "Bun not found. Skipping Playwright."
fi

# ═══════════════════════════════════════════════════════════════════════════
# Quick sanity check (full verification is done by verify.ps1 / verify.sh)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}  Quick sanity check...${NC}"

FAIL=0
for check_cmd in \
  "command -v bun" \
  "command -v claude" \
  "test -d $HOME/.claude/PAI" \
  "grep -qF '# --- PAI environment' ~/.bashrc" \
  "test -s $HOME/.vm-ip"; do
  if ! eval "$check_cmd" &>/dev/null; then
    err "Sanity check failed: $check_cmd"
    FAIL=$((FAIL + 1))
  fi
done

if [ $FAIL -gt 0 ]; then
  err "Provisioning completed with $FAIL failures. Check output above."
  exit 1
fi
log "All sanity checks passed"

# ─── Done ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}============================================${NC}"
echo -e "${BOLD}${GREEN}  PAI-WSL2 Provisioning Complete${NC}"
echo -e "${BOLD}${GREEN}============================================${NC}"
echo ""
log "PAI:          ~/.claude/"
log "Companion:    ~/pai-companion/ (ready for Claude to install)"
log "Workspace:    symlinked to ${NTFS_WORKSPACE}/"
log "Audio:        WSLg PulseAudio at /mnt/wslg/PulseServer"
log "Log:          $LOG_FILE"
echo ""
warn "Next steps -- follow the instructions shown by the installer on Windows."
echo ""
