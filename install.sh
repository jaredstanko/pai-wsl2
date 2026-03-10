#!/bin/bash
# PAI + PAI Companion Install Script for WSL2 (No Docker)
# Run this INSIDE the WSL2 Ubuntu instance.
#
# Usage:
#   bash ~/install.sh
#
# This script installs:
#   1. System packages
#   2. Bun (JavaScript runtime)
#   3. Claude Code CLI
#   4. PAI v4.0 (Personal AI Infrastructure)
#   5. PAI Companion (web portal, file exchange — no Docker)
#   6. Playwright (browser automation)

set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }

echo -e "${BOLD}"
echo "============================================"
echo "  PAI + PAI Companion Installer (WSL2)"
echo "============================================"
echo -e "${NC}"

# -----------------------------------------------------------
# Step 1: Disable Windows drive automount (security)
# -----------------------------------------------------------
log "Disabling Windows drive automount (/mnt/c/) for isolation..."
if grep -q '\[automount\]' /etc/wsl.conf 2>/dev/null; then
    # Update existing automount section
    sudo sed -i 's/^enabled\s*=.*/enabled=false/' /etc/wsl.conf
    if ! grep -q 'enabled=false' /etc/wsl.conf; then
        sudo sed -i '/\[automount\]/a enabled=false' /etc/wsl.conf
    fi
else
    sudo tee -a /etc/wsl.conf >/dev/null <<'WSLCONF'

[automount]
enabled=false
WSLCONF
fi
log "Windows drives will NOT be mounted at /mnt/c/ after next WSL restart."
warn "File transfer uses the claude-workspace symlink on Windows, not /mnt/c/."

# -----------------------------------------------------------
# Step 2: System packages
# -----------------------------------------------------------
log "Installing system packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq curl git zip jq tree tmux wget whois dnsutils imagemagick ffmpeg python3-venv wslu

# -----------------------------------------------------------
# Step 3: Audio setup (WSLg / PulseAudio)
# -----------------------------------------------------------
log "Configuring audio for WSL2..."

# WSLg (Windows 11) provides PulseAudio/PipeWire via /mnt/wslg/
# For Windows 10 without WSLg, we set up PulseAudio to connect to the host
if [ -d "/mnt/wslg" ]; then
    log "WSLg detected — audio passthrough is automatic."
else
    warn "WSLg not detected (Windows 10?). Setting up PulseAudio TCP bridge..."
    sudo apt-get install -y -qq pulseaudio pulseaudio-utils

    # Configure PulseAudio to connect to Windows host
    # User needs to run a PulseAudio server on Windows (e.g., via pulseaudio.exe)
    WIN_HOST=$(ip route show default | awk '{print $3}')
    mkdir -p ~/.config/pulse
    cat > ~/.config/pulse/default.pa <<PULSE
.include /etc/pulse/default.pa
load-module module-native-protocol-tcp auth-anonymous=1
PULSE

    cat > ~/.config/pulse/client.conf <<CONF
default-server = tcp:${WIN_HOST}
autospawn = no
CONF

    warn "For Windows 10 audio: install PulseAudio on Windows and allow TCP connections."
    warn "See README for details."
fi

# -----------------------------------------------------------
# Step 4: Bun
# -----------------------------------------------------------
if command -v bun &>/dev/null; then
    log "Bun already installed: $(bun --version)"
else
    log "Installing Bun..."
    curl -fsSL https://bun.sh/install | bash
    source ~/.bashrc
fi

# Make sure bun is on PATH for the rest of this script
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# -----------------------------------------------------------
# Step 5: Claude Code
# -----------------------------------------------------------
if command -v claude &>/dev/null; then
    log "Claude Code already installed: $(claude --version 2>/dev/null || echo 'installed')"
else
    log "Installing Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash
    export PATH="$HOME/.claude/bin:$PATH"
fi

echo ""
warn "After this script finishes, run 'claude' to authenticate with your Anthropic API key."
echo ""

# -----------------------------------------------------------
# Step 6: PAI v4.0
# -----------------------------------------------------------
if [ -d "$HOME/.claude/PAI" ] || [ -d "$HOME/.claude/skills/PAI" ]; then
    log "PAI appears to be already installed. Skipping."
else
    log "Installing PAI v4.0..."
    cd /tmp
    rm -rf PAI
    git clone https://github.com/danielmiessler/PAI.git
    cd PAI
    LATEST_RELEASE=$(ls Releases/ | sort -V | tail -1)
    log "Using PAI release: $LATEST_RELEASE"
    cp -r "Releases/$LATEST_RELEASE/.claude/" ~/
    cd ~/.claude

    # Fix installer for CLI mode (no GUI available in WSL2 terminal)
    if [ -f install.sh ]; then
        sed -i 's/--mode gui/--mode cli/' install.sh
        bash install.sh
    fi

    # Fix shell config: PAI installer writes to .zshrc, we use bash
    if [ -f ~/.zshrc ]; then
        cat ~/.zshrc >> ~/.bashrc
        # Fix PAI tool paths for the installed layout
        sed -i 's|skills/PAI/Tools/pai.ts|PAI/Tools/pai.ts|g' ~/.bashrc
    fi

    rm -rf /tmp/PAI
    log "PAI installed."
fi

source ~/.bashrc 2>/dev/null || true

# -----------------------------------------------------------
# Step 6b: Claude Code sandbox — restrict to VM + shared folder
# -----------------------------------------------------------
# Runs AFTER PAI install to avoid being overwritten by cp -r .claude/
log "Configuring Claude Code filesystem sandbox..."
if [ -f ~/.claude/settings.json ]; then
    # Merge sandbox config into existing settings using jq
    if command -v jq &>/dev/null; then
        jq '. * {
          "permissions": { "deny": ["Read(//mnt/**)", "Edit(//mnt/**)"] },
          "sandbox": {
            "enabled": true,
            "filesystem": {
              "allowWrite": ["~", "//tmp"],
              "denyRead": ["//mnt"],
              "denyWrite": ["//mnt"]
            }
          }
        }' ~/.claude/settings.json > ~/.claude/settings.json.tmp \
            && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
        log "Merged sandbox config into existing settings.json."
    else
        warn "jq not found — writing sandbox settings.json (existing settings may be lost)."
        cat > ~/.claude/settings.json <<'SETTINGS'
{
  "permissions": {
    "deny": [
      "Read(//mnt/**)",
      "Edit(//mnt/**)"
    ]
  },
  "sandbox": {
    "enabled": true,
    "filesystem": {
      "allowWrite": [
        "~",
        "//tmp"
      ],
      "denyRead": [
        "//mnt"
      ],
      "denyWrite": [
        "//mnt"
      ]
    }
  }
}
SETTINGS
    fi
else
    mkdir -p ~/.claude
    cat > ~/.claude/settings.json <<'SETTINGS'
{
  "permissions": {
    "deny": [
      "Read(//mnt/**)",
      "Edit(//mnt/**)"
    ]
  },
  "sandbox": {
    "enabled": true,
    "filesystem": {
      "allowWrite": [
        "~",
        "//tmp"
      ],
      "denyRead": [
        "//mnt"
      ],
      "denyWrite": [
        "//mnt"
      ]
    }
  }
}
SETTINGS
fi
log "Claude Code sandboxed: /mnt/ blocked at both permission and OS level."

# -----------------------------------------------------------
# Step 7: PAI Companion (no Docker)
# -----------------------------------------------------------
log "Installing PAI Companion..."
cd /tmp
rm -rf pai-companion
git clone https://github.com/chriscantey/pai-companion.git
cd pai-companion

# Create companion directory structure
mkdir -p ~/portal ~/exchange ~/work ~/data ~/upstream

# Copy companion files
if [ -d companion/portal ]; then
    cp -r companion/portal/* ~/portal/ 2>/dev/null || true
fi
if [ -d companion/welcome ]; then
    cp -r companion/welcome/* ~/portal/ 2>/dev/null || true
fi
if [ -d companion/context ]; then
    cp -r companion/context/* ~/.claude/ 2>/dev/null || true
fi
if [ -d companion/scripts ]; then
    cp -r companion/scripts ~/companion-scripts
fi

# Clone upstream repos for reference
cd ~/upstream
[ -d PAI ] || git clone https://github.com/danielmiessler/PAI.git 2>/dev/null || true
[ -d TheAlgorithm ] || git clone https://github.com/danielmiessler/TheAlgorithm.git 2>/dev/null || true

# --- Portal server WITHOUT Docker ---
# Create a simple Bun-based static file server
mkdir -p ~/portal
cat > ~/portal/serve.ts <<'SERVE'
const server = Bun.serve({
  port: 8080,
  hostname: "0.0.0.0",
  async fetch(req) {
    const url = new URL(req.url);
    let path = url.pathname === "/" ? "/index.html" : url.pathname;
    const file = Bun.file(`${import.meta.dir}${path}`);
    if (await file.exists()) {
      return new Response(file);
    }
    return new Response("Not Found", { status: 404 });
  },
});
console.log(`Portal server running on http://0.0.0.0:${server.port}`);
SERVE

# Create a placeholder index.html if none exists
if [ ! -f ~/portal/index.html ]; then
    cat > ~/portal/index.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>PAI Companion Portal</title>
  <style>
    body { background: #0a0a0a; color: #e0e0e0; font-family: system-ui, sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; }
    .container { text-align: center; max-width: 600px; padding: 2rem; }
    h1 { color: #93c5fd; font-size: 2rem; }
    p { color: #9ca3af; line-height: 1.6; }
    .status { color: #4ade80; font-weight: bold; }
  </style>
</head>
<body>
  <div class="container">
    <h1>PAI Companion Portal</h1>
    <p class="status">Online</p>
    <p>Your PAI Companion is running on WSL2. This portal serves dashboards, reports, and file exchange interfaces created by your AI assistant.</p>
  </div>
</body>
</html>
HTML
fi

# Create systemd user service for the portal
# Note: WSL2 requires systemd enabled in /etc/wsl.conf (Ubuntu 22.04+)
if pidof systemd &>/dev/null; then
    mkdir -p ~/.config/systemd/user
    cat > ~/.config/systemd/user/pai-portal.service <<UNIT
[Unit]
Description=PAI Companion Portal Server
After=network.target

[Service]
Type=simple
WorkingDirectory=%h/portal
ExecStart=%h/.bun/bin/bun run serve.ts
Restart=on-failure
Environment=PATH=%h/.bun/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
UNIT

    sudo loginctl enable-linger "$(whoami)" 2>/dev/null || true
    systemctl --user daemon-reload
    systemctl --user enable pai-portal.service
    systemctl --user start pai-portal.service
    log "Portal server started on port 8080 (Bun, systemd)."
else
    warn "systemd not detected in WSL2."
    warn "To enable systemd, add to /etc/wsl.conf:"
    warn "  [boot]"
    warn "  systemd=true"
    warn "Then restart WSL: wsl --shutdown"
    warn ""
    warn "For now, start the portal manually:"
    warn "  cd ~/portal && bun run serve.ts &"

    # Add a bashrc alias as a convenience
    if ! grep -q "pai-portal-start" ~/.bashrc 2>/dev/null; then
        echo '' >> ~/.bashrc
        echo '# PAI Portal manual start (until systemd is enabled)' >> ~/.bashrc
        echo 'alias pai-portal-start="cd ~/portal && nohup bun run serve.ts > ~/portal/server.log 2>&1 &"' >> ~/.bashrc
    fi
fi

# Initialize git tracking for work and .claude directories
cd ~/work && git init -q && git add -A && git commit -q -m "Initial work directory" 2>/dev/null || true
cd ~/.claude && git init -q && git add -A && git commit -q -m "Initial PAI config" 2>/dev/null || true

rm -rf /tmp/pai-companion

# -----------------------------------------------------------
# Step 8: Playwright (optional but recommended)
# -----------------------------------------------------------
log "Installing Playwright..."
if command -v bun &>/dev/null; then
    cd /tmp
    mkdir -p playwright-setup && cd playwright-setup
    bun init -y 2>/dev/null || true
    bun add playwright 2>/dev/null || true
    bunx playwright install --with-deps chromium 2>/dev/null || warn "Playwright install may need manual completion."
    cd /tmp && rm -rf playwright-setup
else
    warn "Bun not found. Skipping Playwright."
fi


# -----------------------------------------------------------
# Done
# -----------------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}============================================${NC}"
echo -e "${BOLD}${GREEN}  Installation Complete (WSL2)${NC}"
echo -e "${BOLD}${GREEN}============================================${NC}"
echo ""
log "PAI:        ~/.claude/"
log "Portal:     http://localhost:8080"
log "Exchange:   ~/exchange/"
log "Work:       ~/work/"
log "Upstream:   ~/upstream/"
log "Home:       /home/claude (shared with host as ~/claude-workspace)"
echo ""

# -----------------------------------------------------------
# Create Windows symlink if not already present
# -----------------------------------------------------------
WIN_USERPROFILE=$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r')
if [ -n "$WIN_USERPROFILE" ]; then
    SYMLINK_PATH="$WIN_USERPROFILE\\claude-workspace"
    WSL_TARGET="\\\\wsl\$\\Ubuntu-24.04\\home\\claude"
    if [ ! -d "$(wslpath "$SYMLINK_PATH" 2>/dev/null)" ]; then
        log "Creating Windows symlink: $SYMLINK_PATH -> $WSL_TARGET"
        cmd.exe /c mklink /d "$SYMLINK_PATH" "$WSL_TARGET" 2>/dev/null && \
            log "Symlink created successfully." || \
            warn "Could not create symlink (may need Administrator). Run in an elevated prompt:"
            warn "  cmd /c mklink /d \"$SYMLINK_PATH\" \"$WSL_TARGET\""
    else
        log "Windows symlink already exists at $SYMLINK_PATH"
    fi
fi

warn "Next steps:"
warn "  1. Run 'claude' to authenticate with your Anthropic API key"
warn "  2. Visit http://localhost:8080 in your Windows browser"
warn "  3. Start using PAI: source ~/.bashrc && pai"
echo ""
