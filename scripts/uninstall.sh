#!/usr/bin/env bash
#
# yappr uninstaller.
#
# Removes yappr components installed by scripts/install.sh:
#   - Unloads and removes the launchd daemon plist
#   - Removes built Swift binaries
#   - Removes shell completions
#   - Warns about PATH entries that must be removed manually
#   - Optionally deletes user data/config/state directories
#
# Non-destructive by default: data directories are only removed if confirmed.

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

YAPPR_DATA_HOME="${YAPPR_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/yappr}"
YAPPR_CONFIG_HOME="${YAPPR_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/yappr}"
YAPPR_STATE_HOME="${YAPPR_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/yappr}"

ASSUME_YES=0

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

print_help() {
  cat <<EOF
yappr uninstaller — removes yappr from macOS.

Usage: $0 [options]

Options:
  -y, --yes    Assume "yes" to all prompts (non-interactive)
  -h, --help   Show this help

Steps:
  1. Unload and remove the launchd daemon plist
  2. Remove built Swift binaries (YapprSttDaemon, YapprSttConnect)
  3. Remove shell completions (bash/zsh/fish)
  4. Warn about shell PATH lines that must be removed manually
  5. Optionally delete user data, config, and state directories
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)  ASSUME_YES=1; shift ;;
    -h|--help) print_help; exit 0 ;;
    *)         echo "unknown option: $1" >&2; print_help >&2; exit 2 ;;
  esac
done

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'
else
  BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; CYAN=""
fi

step() { echo; echo "${BOLD}${CYAN}==>${RESET} ${BOLD}$*${RESET}"; }
ok()   { echo "    ${GREEN}OK${RESET}  $*"; }
warn() { echo "    ${YELLOW}!${RESET}   $*"; }
fail() { echo "${RED}FAIL${RESET} $*" >&2; exit 1; }

prompt_yn() {
  # prompt_yn "Question" [default=Y|N] — returns 0 on yes, 1 on no
  local prompt="$1" default="${2:-Y}" reply suffix
  if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
  if [[ "$default" == "Y" ]]; then suffix="[Y/n]"; else suffix="[y/N]"; fi
  while true; do
    read -rp "    $prompt $suffix " reply
    reply="${reply:-$default}"
    case "$reply" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# 1. Unload launchd service
# -----------------------------------------------------------------------------

step "Unload launchd service"

PLIST_DEST="$HOME/Library/LaunchAgents/com.yappr.daemon.plist"
LAUNCHD_LABEL="com.yappr.daemon"

if [[ -f "$PLIST_DEST" ]]; then
  launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null \
    || launchctl unload "$PLIST_DEST" 2>/dev/null \
    || true
  rm -f "$PLIST_DEST"
  ok "Removed $PLIST_DEST"
else
  warn "Plist already removed: $PLIST_DEST"
fi

# -----------------------------------------------------------------------------
# 2. Remove built Swift binaries
# -----------------------------------------------------------------------------

step "Remove built Swift binaries"

DAEMON_BIN="$YAPPR_DATA_HOME/build/yappr-stt-daemon/release/YapprSttDaemon"
CONNECT_BIN="$YAPPR_DATA_HOME/build/yappr-stt-daemon/release/YapprSttConnect"

if [[ -f "$DAEMON_BIN" ]]; then
  rm -f "$DAEMON_BIN"
  ok "Removed YapprSttDaemon"
else
  warn "YapprSttDaemon not found: $DAEMON_BIN"
fi

if [[ -f "$CONNECT_BIN" ]]; then
  rm -f "$CONNECT_BIN"
  ok "Removed YapprSttConnect"
else
  warn "YapprSttConnect not found: $CONNECT_BIN"
fi

# -----------------------------------------------------------------------------
# 3. Remove shell completions
# -----------------------------------------------------------------------------

step "Remove shell completions"

SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"

case "$SHELL_NAME" in
  bash)
    BASH_COMPLETION="$HOME/.bash_completion.d/yappr"
    if [[ -f "$BASH_COMPLETION" ]]; then
      rm -f "$BASH_COMPLETION"
      ok "Removed bash completion: $BASH_COMPLETION"
    else
      warn "bash completion not found: $BASH_COMPLETION"
    fi
    ;;
  zsh)
    ZSH_COMPLETION="$HOME/.zfunctions/_yappr"
    if [[ -f "$ZSH_COMPLETION" ]]; then
      rm -f "$ZSH_COMPLETION"
      ok "Removed zsh completion: $ZSH_COMPLETION"
    else
      warn "zsh completion not found: $ZSH_COMPLETION"
    fi
    ;;
  fish)
    FISH_COMPLETION="$HOME/.config/fish/completions/yappr.fish"
    if [[ -f "$FISH_COMPLETION" ]]; then
      rm -f "$FISH_COMPLETION"
      ok "Removed fish completion: $FISH_COMPLETION"
    else
      warn "fish completion not found: $FISH_COMPLETION"
    fi
    ;;
  *)
    warn "Unknown shell ($SHELL_NAME). Remove completions manually from:"
    warn "  bash: ~/.bash_completion.d/yappr"
    warn "  zsh:  ~/.zfunctions/_yappr"
    warn "  fish: ~/.config/fish/completions/yappr.fish"
    ;;
esac

# -----------------------------------------------------------------------------
# 4. Shell PATH entries (manual removal required)
# -----------------------------------------------------------------------------

step "Shell PATH entries"

RC_FILES=(
  "$HOME/.bashrc"
  "$HOME/.zshrc"
  "$HOME/.config/fish/config.fish"
)

FOUND_PATH_ENTRY=0
for rc in "${RC_FILES[@]}"; do
  if [[ -f "$rc" ]] && grep -q 'yappr.*bin\|bin.*yappr' "$rc" 2>/dev/null; then
    warn "Cannot auto-remove PATH entries from $rc"
    warn "Remove the yappr/bin/ line(s) manually, e.g.:"
    grep -n 'yappr.*bin\|bin.*yappr' "$rc" | while IFS= read -r line; do
      warn "  $rc:$line"
    done
    FOUND_PATH_ENTRY=1
  fi
done

if [[ $FOUND_PATH_ENTRY -eq 0 ]]; then
  ok "No shell PATH entries found"
fi

# -----------------------------------------------------------------------------
# 5. User data directories
# -----------------------------------------------------------------------------

step "User data directories"

USER_DIRS=(
  "$YAPPR_CONFIG_HOME"
  "$YAPPR_STATE_HOME"
  "$YAPPR_DATA_HOME"
)

for dir in "${USER_DIRS[@]}"; do
  if [[ -d "$dir" ]]; then
    if prompt_yn "Delete $dir?" "N"; then
      rm -rf "$dir"
      ok "Deleted $dir"
    else
      warn "Skipped $dir"
    fi
  fi
done

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------

echo
echo "${BOLD}${GREEN}yappr uninstalled.${RESET}"
echo "${DIM}If you granted Microphone/Accessibility/Input Monitoring permissions,"
echo "revoke them in System Settings → Privacy & Security.${RESET}"
