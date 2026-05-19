#!/usr/bin/env bash
#
# yappr installer.
#
# Sets up everything needed to run yappr on a fresh macOS Apple Silicon machine:
#   - Xcode CLI tools (system-level)
#   - Homebrew packages (jq, python@3.12)
#   - Optional: Hammerspoon (push-to-talk hotkey), mlx-lm (local LLM)
#   - Builds and ad-hoc codesigns the Swift STT daemon
#   - Adds bin/ to your shell PATH
#
# Idempotent: safe to re-run. Steps that are already complete are skipped.
#
# What the script CANNOT do for you (you'll be prompted by macOS later):
#   - Grant Microphone TCC permission to the daemon
#   - Grant Hammerspoon Accessibility + Input Monitoring permissions
#   - Configure your LLM endpoint (edit configs/active.json yourself)

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAPPR_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DAEMON_DIR="$YAPPR_ROOT/swift/yappr-stt-daemon"
DAEMON_BIN="$DAEMON_DIR/.build/release/YapprSttDaemon"
CONNECT_BIN="$DAEMON_DIR/.build/release/YapprSttConnect"

REQUIRED_FORMULAS=("jq" "python@3.12")

ASSUME_YES=0
SKIP_OPTIONAL=0

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

print_help() {
  cat <<EOF
yappr installer — sets up yappr on macOS Apple Silicon.

Usage: $0 [options]

Options:
  -y, --yes              Assume "yes" to all prompts (non-interactive)
      --skip-optional    Skip optional components (Hammerspoon, mlx-lm)
  -h, --help             Show this help

Steps:
  1. Sanity check: macOS + Apple Silicon
  2. Xcode CLI tools
  3. Homebrew presence
  4. Required Homebrew packages: ${REQUIRED_FORMULAS[*]}
  5. Optional: Hammerspoon (push-to-talk)
  6. Optional: mlx-lm (local LLM)
  7. Build yappr-stt-daemon (Swift)
  8. Ad-hoc codesign so TCC permission survives rebuilds
  9. Add yappr/bin/ to your shell PATH

After install, you'll be told how to start the daemon and grant permissions.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)           ASSUME_YES=1; shift ;;
    --skip-optional)    SKIP_OPTIONAL=1; shift ;;
    -h|--help)          print_help; exit 0 ;;
    *)                  echo "unknown option: $1" >&2; print_help >&2; exit 2 ;;
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
info() { echo "    $*"; }
ok()   { echo "    ${GREEN}OK${RESET}  $*"; }
warn() { echo "    ${YELLOW}!${RESET}   $*"; }
fail() { echo "${RED}FAIL${RESET} $*" >&2; exit 1; }

prompt_yn() {
  # prompt_yn "Question" [default=Y|N] — returns 0 on yes, 1 on no
  local prompt="$1" default="${2:-Y}" reply suffix
  if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
  if [[ "$default" == "Y" ]]; then suffix="[Y/n]"; else suffix="[y/N]"; fi
  while true; do
    read -p "    $prompt $suffix " reply
    reply="${reply:-$default}"
    case "$reply" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# 1. Sanity checks
# -----------------------------------------------------------------------------

step "Checking environment"

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "yappr requires macOS. Detected: $(uname -s)."
fi
ok "macOS detected"

if [[ "$(uname -m)" != "arm64" ]]; then
  warn "Detected Intel Mac. yappr targets Apple Silicon."
  warn "Nemotron 0.6B may not perform well on Intel."
  prompt_yn "Continue anyway?" "N" || fail "Aborted."
else
  ok "Apple Silicon detected ($(uname -m))"
fi

if [[ ! -d "$DAEMON_DIR" ]]; then
  fail "Cannot find daemon source at $DAEMON_DIR. Is this a yappr checkout?"
fi
ok "Repo root: $YAPPR_ROOT"

# -----------------------------------------------------------------------------
# 2. Xcode CLI tools
# -----------------------------------------------------------------------------

step "Xcode command-line tools"

if xcode-select -p >/dev/null 2>&1; then
  ok "Already installed at $(xcode-select -p)"
else
  info "Not installed. Triggering 'xcode-select --install' — a system dialog will appear."
  xcode-select --install || true
  echo
  info "Wait for the install to finish, then re-run this script."
  exit 0
fi

# -----------------------------------------------------------------------------
# 3. Homebrew
# -----------------------------------------------------------------------------

step "Homebrew"

if ! command -v brew >/dev/null 2>&1; then
  fail "Homebrew not installed. Install from https://brew.sh then re-run."
fi
ok "$(brew --version | head -1)"

# -----------------------------------------------------------------------------
# 4. Required Homebrew formulas
# -----------------------------------------------------------------------------

step "Required Homebrew packages"

MISSING_FORMULAS=()
for formula in "${REQUIRED_FORMULAS[@]}"; do
  if brew list --formula "$formula" >/dev/null 2>&1; then
    ok "$formula"
  else
    MISSING_FORMULAS+=("$formula")
  fi
done

if [[ ${#MISSING_FORMULAS[@]} -gt 0 ]]; then
  info "Installing: ${MISSING_FORMULAS[*]}"
  brew install "${MISSING_FORMULAS[@]}"
  for f in "${MISSING_FORMULAS[@]}"; do ok "Installed $f"; done
fi

# -----------------------------------------------------------------------------
# 5. Optional: Hammerspoon
# -----------------------------------------------------------------------------

if [[ $SKIP_OPTIONAL -eq 0 ]]; then
  step "Hammerspoon (optional — for push-to-talk hotkey)"

  if [[ -d "/Applications/Hammerspoon.app" ]] || brew list --cask hammerspoon >/dev/null 2>&1; then
    ok "Hammerspoon already installed"
  else
    info "Without Hammerspoon, you can still use yappr in CLI mode (terminal only)."
    if prompt_yn "Install Hammerspoon now?"; then
      brew install --cask hammerspoon
      ok "Installed Hammerspoon"
      info "Launch Hammerspoon once and grant Accessibility + Input Monitoring permissions."
    else
      warn "Skipped Hammerspoon. CLI mode only."
    fi
  fi
fi

# -----------------------------------------------------------------------------
# 6. Optional: mlx-lm
# -----------------------------------------------------------------------------

if [[ $SKIP_OPTIONAL -eq 0 ]]; then
  step "MLX local LLM (optional — for on-device cleanup)"

  if command -v mlx_lm.server >/dev/null 2>&1; then
    ok "mlx-lm already installed"
  else
    info "Without mlx-lm, you must point configs/active.json at an OpenAI-compatible endpoint."
    if prompt_yn "Install mlx-lm via uv?"; then
      if ! command -v uv >/dev/null 2>&1; then
        info "Installing uv first..."
        brew install uv
      fi
      uv tool install mlx-lm
      ok "Installed mlx-lm (mlx_lm.server now on PATH)"
    else
      warn "Skipped mlx-lm. You will need an external LLM endpoint."
    fi
  fi
fi

# -----------------------------------------------------------------------------
# 7. Build the Swift daemon
# -----------------------------------------------------------------------------

step "Build yappr-stt-daemon"

NEED_BUILD=1
if [[ -x "$DAEMON_BIN" ]] && [[ -x "$CONNECT_BIN" ]]; then
  # Check if any source is newer than the binary
  if [[ -z "$(find "$DAEMON_DIR/Sources" -type f -newer "$DAEMON_BIN" -print -quit 2>/dev/null)" ]]; then
    ok "Binaries up to date"
    NEED_BUILD=0
  fi
fi

if [[ $NEED_BUILD -eq 1 ]]; then
  info "Building (first build can take ~30s)..."
  (cd "$DAEMON_DIR" && swift build -c release)
  ok "Built YapprSttDaemon"
  ok "Built YapprSttConnect"
fi

# -----------------------------------------------------------------------------
# 8. Ad-hoc codesign
# -----------------------------------------------------------------------------

step "Codesign daemon binaries"

info "TCC keys microphone permission by code-signing identity. An ad-hoc"
info "signature gives the binary a stable identity across rebuilds, so you"
info "only have to grant the macOS Microphone prompt once."

codesign --force --sign - "$DAEMON_BIN"
ok "Signed YapprSttDaemon"
codesign --force --sign - "$CONNECT_BIN"
ok "Signed YapprSttConnect"

# -----------------------------------------------------------------------------
# 9. Shell PATH
# -----------------------------------------------------------------------------

step "Shell PATH"

YAPPR_BIN="$YAPPR_ROOT/bin"

# Detect the user's preferred shell from $SHELL.
SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"
case "$SHELL_NAME" in
  zsh)  RC_FILE="$HOME/.zshrc" ;;
  bash) RC_FILE="$HOME/.bashrc" ;;
  fish) RC_FILE="$HOME/.config/fish/config.fish" ;;
  *)    RC_FILE="" ;;
esac

if echo ":$PATH:" | grep -q ":$YAPPR_BIN:"; then
  ok "$YAPPR_BIN already on PATH"
elif [[ -z "$RC_FILE" ]]; then
  warn "Unknown shell ($SHELL_NAME). Add this to your shell rc manually:"
  warn "    export PATH=\"$YAPPR_BIN:\$PATH\""
elif [[ -f "$RC_FILE" ]] && grep -q "$YAPPR_BIN" "$RC_FILE" 2>/dev/null; then
  ok "$RC_FILE already references $YAPPR_BIN — restart your shell to pick it up"
else
  info "Will add this line to $RC_FILE:"
  if [[ "$SHELL_NAME" == "fish" ]]; then
    info "    set -gx PATH $YAPPR_BIN \$PATH"
  else
    info "    export PATH=\"$YAPPR_BIN:\$PATH\""
  fi
  if prompt_yn "Add yappr/bin/ to $RC_FILE?"; then
    {
      echo ""
      echo "# yappr CLI (added by scripts/install.sh)"
      if [[ "$SHELL_NAME" == "fish" ]]; then
        echo "set -gx PATH $YAPPR_BIN \$PATH"
      else
        echo "export PATH=\"$YAPPR_BIN:\$PATH\""
      fi
    } >> "$RC_FILE"
    ok "Added. Restart your shell or run: source $RC_FILE"
  else
    warn "Skipped. Run yappr commands with the full path: $YAPPR_BIN/yappr"
  fi
fi

# -----------------------------------------------------------------------------
# 10. Summary
# -----------------------------------------------------------------------------

cat <<EOF

${BOLD}${GREEN}Install complete.${RESET}

${BOLD}Next steps:${RESET}

  ${BOLD}1.${RESET} Start the daemon:
       $DAEMON_BIN
     On first launch, macOS will prompt for Microphone access. Grant it.
     Leave the daemon running (in a tab, screen/tmux, or set up launchd
     yourself if you want auto-start at login).

  ${BOLD}2.${RESET} Verify the socket appeared:
       ls /tmp/yappr-stt.sock

  ${BOLD}3.${RESET} Configure your LLM endpoint:
       jq -r .llm.url "$YAPPR_ROOT/configs/active.json"
     Default is local MLX at 127.0.0.1:8081. Edit if needed:
       $YAPPR_BIN/yappr-config edit

  ${BOLD}4.${RESET} (Hammerspoon users) Wire up the push-to-talk hotkey:
       See $YAPPR_ROOT/docs/installation.md (Hammerspoon section)
       Grant Accessibility + Input Monitoring when prompted.

  ${BOLD}5.${RESET} Test it:
       In one terminal: $YAPPR_BIN/yappr-trace --tail
       Hold your hotkey or run $YAPPR_BIN/yappr directly.

For the full reference: $YAPPR_ROOT/docs/installation.md
EOF
