#!/bin/bash
# PAI-WSL2 — WSL-Side Verification
# Checks that all tools and configuration are present inside the WSL2 distro.
# Uses 2-state model: PASS (present and working), FAIL (missing or broken).
#
# Can be run standalone inside WSL or called by verify.ps1 from the host.
#
# Usage:
#   bash verify.sh

set -uo pipefail

# ─── Colors ─────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

PASS=0
FAIL=0

# ─── Helpers ────────────────────────────────────────────────────────────────

passed() {
  local label="$1"
  local detail="${2:-}"
  if [ -n "$detail" ]; then
    printf "  ${GREEN}%-8s${NC} %-40s %s\n" "PASS" "$label" "$detail"
  else
    printf "  ${GREEN}%-8s${NC} %s\n" "PASS" "$label"
  fi
  PASS=$((PASS + 1))
}

failed() {
  local label="$1"
  local detail="${2:-}"
  if [ -n "$detail" ]; then
    printf "  ${RED}%-8s${NC} %-40s %s\n" "FAIL" "$label" "$detail"
  else
    printf "  ${RED}%-8s${NC} %s\n" "FAIL" "$label"
  fi
  FAIL=$((FAIL + 1))
}

check_installed() {
  local label="$1"
  local actual="$2"

  if [ -n "$actual" ] && [ "$actual" != "MISSING" ]; then
    passed "$label" "($actual)"
  else
    failed "$label"
  fi
}

# ─── Bun ────────────────────────────────────────────────────────────────────
BUN_VER="MISSING"
if command -v bun &>/dev/null; then
  BUN_VER=$(bun --version 2>/dev/null || echo "MISSING")
fi
check_installed "Bun" "$BUN_VER"

# ─── Claude Code ────────────────────────────────────────────────────────────
CLAUDE_VER="MISSING"
if command -v claude &>/dev/null; then
  CLAUDE_VER=$(claude --version 2>/dev/null | grep -oE '[0-9.]+' | head -1 || echo "MISSING")
fi
check_installed "Claude Code" "$CLAUDE_VER"

# ─── Node.js ───────────────────────────────────────────────────────────────
NODE_VER="MISSING"
if command -v node &>/dev/null; then
  NODE_VER=$(node --version 2>/dev/null || echo "MISSING")
fi
check_installed "Node.js" "$NODE_VER"

# ─── PAI directory ─────────────────────────────────────────────────────────
if [ -d "$HOME/.claude/PAI" ]; then
  passed "PAI directory"
else
  failed "PAI directory" "(~/.claude/PAI not found)"
fi

# ─── PAI skill symlink ────────────────────────────────────────────────────
if [ -L "$HOME/.claude/skills/PAI" ]; then
  passed "PAI skill symlink"
else
  failed "PAI skill symlink" "(~/.claude/skills/PAI not linked)"
fi

# ─── .bashrc PAI environment block ────────────────────────────────────────
if grep -qF "# --- PAI environment" ~/.bashrc 2>/dev/null; then
  passed ".bashrc PAI environment block"
else
  failed ".bashrc PAI environment block"
fi

# ─── .zshrc PAI environment block ─────────────────────────────────────────
if grep -qF "# --- PAI environment" ~/.zshrc 2>/dev/null; then
  passed ".zshrc PAI environment block"
else
  failed ".zshrc PAI environment block"
fi

# ─── PAI Companion ────────────────────────────────────────────────────────
if [ -d "$HOME/pai-companion/companion" ]; then
  passed "PAI Companion repo"
else
  failed "PAI Companion repo" "(~/pai-companion/companion not found)"
fi

# ─── Playwright ───────────────────────────────────────────────────────────
PW_VER="MISSING"
if command -v bunx &>/dev/null; then
  PW_VER=$(bunx playwright --version 2>/dev/null || echo "MISSING")
fi
check_installed "Playwright" "$PW_VER"

# ─── Mount accessibility ─────────────────────────────────────────────────
# Check the 5 user-facing dirs (symlinks to NTFS) + claude-home on ext4
MOUNTS_OK=true
for mount_dir in data exchange portal work upstream; do
  if [ -d "$HOME/$mount_dir" ] || [ -L "$HOME/$mount_dir" ]; then
    : # ok
  else
    MOUNTS_OK=false
    failed "Mount: ~/$mount_dir"
  fi
done

# claude-home is the .claude directory itself
if [ -d "$HOME/.claude" ]; then
  : # ok
else
  MOUNTS_OK=false
  failed "Mount: ~/.claude"
fi

if [ "$MOUNTS_OK" = true ]; then
  passed "Mount points accessible (6/6)"
fi

# ─── WSLg PulseAudio socket ──────────────────────────────────────────────
if [ -e "/mnt/wslg/PulseServer" ]; then
  passed "WSLg PulseAudio socket" "(/mnt/wslg/PulseServer)"
else
  failed "WSLg PulseAudio socket" "(/mnt/wslg/PulseServer not found — WSLg may not be enabled)"
fi

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "  ──────────────────────────────────────────────"
TOTAL=$((PASS + FAIL))
printf "  ${GREEN}%d PASS${NC}  ${RED}%d FAIL${NC}  (%d checks)\n" "$PASS" "$FAIL" "$TOTAL"
echo ""

if [ $FAIL -gt 0 ]; then
  echo -e "  ${RED}Some checks failed.${NC} Review output above for details."
  exit 1
else
  echo -e "  ${GREEN}All checks passed.${NC}"
  exit 0
fi
