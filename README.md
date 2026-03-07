# pai-wsl2

PAI + PAI Companion running on WSL2 (Ubuntu 24.04) with audio passthrough on Windows. No Docker.

This is the Windows/WSL2 adaptation of [pai-lima](https://github.com/quinn-pai/pai-lima), which targets macOS with Lima VMs.

## What This Sets Up

- **WSL2** — Ubuntu 24.04 on Windows via the Windows Subsystem for Linux
- **Audio** — WSLg passthrough (Windows 11) or PulseAudio TCP bridge (Windows 10)
- **PAI v4.0** — [Personal AI Infrastructure](https://github.com/danielmiessler/Personal_AI_Infrastructure)
- **PAI Companion** — [Web portal, file exchange, context enhancements](https://github.com/chriscantey/pai-companion) (portal served via Bun, not Docker)
- **Shared folder** — `%USERPROFILE%\claude-workspace` on Windows ↔ `/claude-workspace` in WSL2

## Prerequisites

- Windows 10 version 2004+ (build 19041+) or Windows 11
- WSL2 capable hardware (virtualization enabled in BIOS)
- An Anthropic API key for Claude Code

## Quick Start

```powershell
# 1. Clone this repo (in PowerShell)
git clone https://github.com/quinn-pai/pai-wsl2.git
cd pai-wsl2

# 2. Run the Windows setup (as Administrator)
Set-ExecutionPolicy Bypass -Scope Process -Force
.\setup-wsl.ps1

# 3. Launch Ubuntu 24.04 from Start Menu
#    (first launch: create user 'claude' when prompted)

# 4. Inside WSL2, run the install script
bash /mnt/c/Users/<YourWindowsUser>/claude-workspace/install.sh
```

## Windows Setup (setup-wsl.ps1)

The PowerShell script handles the Windows side:

1. **Enables WSL2** — activates the WSL and Virtual Machine Platform features
2. **Installs Ubuntu 24.04** — via `wsl --install -d Ubuntu-24.04`
3. **Creates .wslconfig** — sets 4 CPUs, 4GB RAM, 2GB swap
4. **Creates shared workspace** — `%USERPROFILE%\claude-workspace`
5. **Copies install.sh** — into the shared workspace for WSL2 access

> **Note:** If the Virtual Machine Platform feature was just enabled, you must reboot and re-run the script.

## Installing PAI + PAI Companion

From inside WSL2 (Ubuntu 24.04):

```bash
bash /mnt/c/Users/<YourWindowsUser>/claude-workspace/install.sh
```

The script installs (in order):

1. **System packages** — curl, git, zip, jq, tree, tmux, ffmpeg, imagemagick, wslu, etc.
2. **Audio** — WSLg auto-detection or PulseAudio TCP bridge setup
3. **Bun** — JavaScript runtime
4. **Claude Code** — Anthropic's CLI
5. **PAI v4.0** — clones the latest release and runs the installer in CLI mode
6. **PAI Companion** — clones the companion repo, sets up portal/exchange/work directories, starts the portal web server on port 8080 using Bun (no Docker)
7. **Playwright** — browser automation with Chromium
8. **Workspace symlink** — `/claude-workspace` → shared Windows folder

### After installation

```bash
# Authenticate Claude Code
claude

# Activate PAI
source ~/.bashrc
pai
```

### Access the companion portal

From your Windows browser, visit:

```
http://localhost:8080
```

WSL2 automatically forwards ports to localhost on Windows.

## Configuration

### VM Resources (.wslconfig)

The setup script creates `%USERPROFILE%\.wslconfig`:

| Setting | Value |
|---------|-------|
| Memory | 4 GB |
| Processors | 4 |
| Swap | 2 GB |
| Auto memory reclaim | gradual |
| Sparse VHD | true |

Edit this file and restart WSL (`wsl --shutdown`) to change settings.

### Enabling systemd

Ubuntu 24.04 on WSL2 has systemd enabled by default. If it's not working, add to `/etc/wsl.conf`:

```ini
[boot]
systemd=true
```

Then restart WSL:

```powershell
wsl --shutdown
```

Without systemd, start the portal manually:

```bash
pai-portal-start   # alias added by install.sh
```

## Audio

### Windows 11 (WSLg)

Audio works automatically via WSLg. No configuration needed.

```bash
# Verify audio
aplay -l
speaker-test -t sine -f 440 -l 1 -p 2
```

### Windows 10 (PulseAudio TCP Bridge)

Windows 10 lacks WSLg. The install script configures PulseAudio to connect to the Windows host, but you need a PulseAudio server on Windows:

1. Download [PulseAudio for Windows](https://www.freedesktop.org/wiki/Software/PulseAudio/Ports/Windows/Support/)
2. Edit `etc/pulse/default.pa` and add:
   ```
   load-module module-native-protocol-tcp auth-anonymous=1
   ```
3. Run `bin/pulseaudio.exe`
4. Inside WSL2, test with `speaker-test`

## WSL2 Management

```powershell
# Stop WSL2
wsl --shutdown

# Restart a specific distro
wsl -t Ubuntu-24.04
wsl -d Ubuntu-24.04

# List installed distros
wsl -l -v

# Set Ubuntu 24.04 as default
wsl --set-default Ubuntu-24.04

# Export/backup the distro
wsl --export Ubuntu-24.04 pai-backup.tar

# Import from backup
wsl --import Ubuntu-24.04-restored C:\WSL\restored pai-backup.tar
```

## Directory Layout (inside WSL2)

```
/claude-workspace/   Symlink to Windows shared folder
~/portal/            Companion web portal (served on :8080)
~/exchange/          File exchange directory
~/work/              Project workspace (git tracked)
~/data/              Data storage
~/upstream/          Reference repos (PAI, TheAlgorithm)
~/.claude/           PAI configuration and skills
```

## Differences from pai-lima (macOS)

| Feature | pai-lima (macOS) | pai-wsl2 (Windows) |
|---------|-----------------|-------------------|
| VM layer | Lima + VZ framework | WSL2 + Hyper-V |
| Architecture | ARM64 (Apple Silicon) | x86_64 (typically) |
| Audio | VirtIO sound device | WSLg (Win 11) or PulseAudio TCP (Win 10) |
| Shared folder | Lima mount (`~/claude-workspace`) | Windows drive mount (`/mnt/c/...`) |
| Port forwarding | Manual (VM IP) | Automatic (localhost) |
| VM config | `linux.yaml` | `.wslconfig` |
| Setup script | `brew install lima` | `setup-wsl.ps1` (PowerShell) |

## Troubleshooting

**WSL2 won't install:** Ensure virtualization is enabled in your BIOS/UEFI settings. Check with `systeminfo` in cmd — "Hyper-V Requirements" should all say "Yes".

**"Please enable the Virtual Machine Platform" error:** Run `setup-wsl.ps1` as Administrator and reboot when prompted.

**No audio (Windows 11):** Make sure WSLg is working: `ls /mnt/wslg/`. If missing, update WSL: `wsl --update`.

**No audio (Windows 10):** You need PulseAudio running on Windows with TCP module loaded. See the Audio section above.

**Portal not accessible:** Check if the service is running: `systemctl --user status pai-portal`. If systemd isn't enabled, use `pai-portal-start`.

**Slow filesystem on /mnt/c/:** This is expected — cross-OS filesystem access is slow in WSL2. Keep working files inside the WSL2 filesystem (`~/work/`) and use `/claude-workspace` only for file exchange.

**DNS resolution fails:** Add to `/etc/wsl.conf`:
```ini
[network]
generateResolvConf=false
```
Then `echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf`.

## Credits

- [WSL2](https://learn.microsoft.com/en-us/windows/wsl/) — Windows Subsystem for Linux
- [PAI](https://github.com/danielmiessler/Personal_AI_Infrastructure) — Personal AI Infrastructure by Daniel Miessler
- [PAI Companion](https://github.com/chriscantey/pai-companion) — Companion package by Chris Cantey
- [pai-lima](https://github.com/quinn-pai/pai-lima) — Original macOS version
