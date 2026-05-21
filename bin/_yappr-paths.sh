# shellcheck shell=bash
# _yappr-paths.sh — source this file (do not execute directly).
# Sets and exports all YAPPR_* path env vars with XDG-based defaults.
# Every variable is overridable by the caller's environment.

# Repo root: prefer env var, fall back to self-detection from this file's location.
YAPPR_ROOT="${YAPPR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export YAPPR_ROOT

# Asset root: Homebrew installs place configs/prompts/scripts in share/yappr/
# rather than at the repo root. YAPPR_SHARE points to whichever exists.
if [[ -d "$YAPPR_ROOT/share/yappr" ]]; then
  YAPPR_SHARE="$YAPPR_ROOT/share/yappr"
else
  YAPPR_SHARE="$YAPPR_ROOT"
fi
export YAPPR_SHARE

# XDG-based dirs (macOS-compatible defaults)
YAPPR_CONFIG_HOME="${YAPPR_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/yappr}"
YAPPR_DATA_HOME="${YAPPR_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/yappr}"
YAPPR_STATE_HOME="${YAPPR_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/yappr}"
YAPPR_CACHE_HOME="${YAPPR_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/yappr}"
YAPPR_RUNTIME_DIR="${YAPPR_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/tmp/yappr-$(id -u)}}"
export YAPPR_CONFIG_HOME YAPPR_DATA_HOME YAPPR_STATE_HOME YAPPR_CACHE_HOME YAPPR_RUNTIME_DIR

# Derived paths — also overridable
YAPPR_SOCKET="${YAPPR_SOCKET:-$YAPPR_RUNTIME_DIR/stt.sock}"
YAPPR_TRACE_LOG="${YAPPR_TRACE_LOG:-$YAPPR_RUNTIME_DIR/trace.log}"
YAPPR_DAEMON_LOG="${YAPPR_DAEMON_LOG:-$YAPPR_STATE_HOME/logs/daemon.log}"
YAPPR_DAEMON_PID="${YAPPR_DAEMON_PID:-$YAPPR_RUNTIME_DIR/daemon.pid}"
export YAPPR_SOCKET YAPPR_TRACE_LOG YAPPR_DAEMON_LOG YAPPR_DAEMON_PID

# Config resolution: user dir first, shipped defaults second
YAPPR_CONFIG="${YAPPR_CONFIG:-$YAPPR_CONFIG_HOME/configs/active.json}"
if [[ ! -f "$YAPPR_CONFIG" ]]; then
  YAPPR_CONFIG="$YAPPR_SHARE/configs/active.json"
fi
export YAPPR_CONFIG

# Build output (outside repo source tree)
YAPPR_BUILD_DIR="${YAPPR_BUILD_DIR:-$YAPPR_DATA_HOME/build}"
export YAPPR_BUILD_DIR

# Helpers -----------------------------------------------------------------------

# Create all runtime and state dirs that yappr scripts need.
yappr_ensure_dirs() {
  mkdir -p \
    "$YAPPR_STATE_HOME/logs" \
    "$YAPPR_STATE_HOME/metrics" \
    "$YAPPR_RUNTIME_DIR"
  chmod 0700 "$YAPPR_RUNTIME_DIR"
}

# Resolve the current metrics file path (state/metrics/YYYY-MM.jsonl)
yappr_metric_path() {
  echo "$YAPPR_STATE_HOME/metrics/$(date +%Y-%m).jsonl"
}

# Resolve a timestamped log path under state/logs/
yappr_log_path() {
  echo "$YAPPR_STATE_HOME/logs/$(date +%Y%m%d-%H%M%S).log"
}

# Path to the built YapprSttConnect binary
yappr_connect_binary() {
  local beside
  beside="$(dirname "${BASH_SOURCE[0]}")/YapprSttConnect"
  if [[ -x "$beside" ]]; then echo "$beside"
  else echo "$YAPPR_BUILD_DIR/yappr-stt-daemon/release/YapprSttConnect"
  fi
}

# Path to the built YapprSttDaemon binary
yappr_daemon_binary() {
  local beside
  beside="$(dirname "${BASH_SOURCE[0]}")/YapprSttDaemon"
  if [[ -x "$beside" ]]; then echo "$beside"
  else echo "$YAPPR_BUILD_DIR/yappr-stt-daemon/release/YapprSttDaemon"
  fi
}
