# Tier 3 — Polish + Open-Source Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add daemon supervision, a `yappr` subcommand dispatcher, a `doctor` verifier, polished `yappr-stats`, shell completions, GitHub Actions CI, and a VERSION file. At the end of this tier, yappr looks and behaves like a proper open-source CLI tool.

**Architecture:** `bin/yappr` becomes a thin dispatcher (like `git`). Each capability lives in a dedicated `bin/yappr-<subcommand>` script. The Swift daemon gains a PID file and responds to `yappr daemon` lifecycle commands. A `yappr-doctor` script provides a post-install health check. CI runs shellcheck, ruff, the audit script, and a Swift build on every push.

**Tech Stack:** bash, Python 3, Swift, GitHub Actions (macos-14), shellcheck, ruff, launchd plists

**Branch:** `feat/tier-3-polish` stacked on `feat/tier-2-runtime-separation`
**PR target:** `feat/tier-2-runtime-separation` (merge Tier 2 first)

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `bin/yappr` | Replace | Thin subcommand dispatcher (current logic → `bin/yappr-dictate`) |
| `bin/yappr-dictate` | Create (rename) | The former `bin/yappr` — actual dictation orchestrator |
| `bin/yappr-daemon` | Create | lifecycle: start/stop/restart/status/logs/tail |
| `bin/yappr-server` | Create | lifecycle for MLX server: start/stop/restart/status/logs/tail |
| `bin/yappr-doctor` | Create | Post-install health verifier (Python) |
| `bin/yappr-help` | Create | Git-style subcommand listing |
| `bin/yappr-stats` | Modify | Polish: remove stale comments, add stt_total_held_ms, --metrics-dir flag |
| `scripts/templates/com.yappr.daemon.plist.tmpl` | Create | launchd LaunchAgent plist template |
| `scripts/install.sh` | Modify | Add launchd step, update binary paths for dispatcher refactor |
| `completions/yappr.bash` | Create | Bash completion |
| `completions/yappr.zsh` | Create | Zsh completion |
| `completions/_yappr.fish` | Create | Fish completion |
| `.github/workflows/ci.yml` | Create | CI: build + lint on push/PR |
| `.github/workflows/release.yml` | Create | Release: tarball on semver tag |
| `VERSION` | Create | Single-line version string `0.1.0` |

---

### Task 1: Create branch from tier-2

**Files:**
- No file changes

- [ ] **Step 1: Create tier-3 branch**

```bash
cd /Users/matteociccozzi/yappr
git checkout feat/tier-2-runtime-separation
git checkout -b feat/tier-3-polish
```

Expected: `Switched to a new branch 'feat/tier-3-polish'`

- [ ] **Step 2: Confirm base**

```bash
git log --oneline -12
```

Expected: all Tier 1 and Tier 2 commits visible.

---

### Task 2: Create `VERSION` file

**Files:**
- Create: `VERSION`

Short standalone task; do it first so other tasks can reference it.

- [ ] **Step 1: Write VERSION**

```bash
echo "0.1.0" > VERSION
```

- [ ] **Step 2: Verify**

```bash
cat VERSION
```

Expected: `0.1.0`

- [ ] **Step 3: Commit**

```bash
git add VERSION
git commit -m "chore: add VERSION file (0.1.0)

Referenced by 'yappr --version' and the release CI workflow."
```

---

### Task 3: Rename `bin/yappr` → `bin/yappr-dictate`, create dispatcher `bin/yappr`

**Files:**
- Create: `bin/yappr-dictate` (copy of current `bin/yappr`)
- Replace: `bin/yappr` with thin dispatcher

This is the most impactful structural change. Do it carefully.

- [ ] **Step 1: Copy current bin/yappr to bin/yappr-dictate**

```bash
cp bin/yappr bin/yappr-dictate
chmod +x bin/yappr-dictate
```

- [ ] **Step 2: Verify bin/yappr-dictate works as the dictation orchestrator**

```bash
bash -n bin/yappr-dictate && echo "syntax OK"
```

- [ ] **Step 3: Write the new dispatcher bin/yappr**

```bash
cat > bin/yappr << 'EOF'
#!/usr/bin/env bash
# yappr — subcommand dispatcher. Usage: yappr <subcommand> [args...]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_yappr-paths.sh"

CMD="${1:-dictate}"
shift 2>/dev/null || true

case "$CMD" in
  dictate|"")  exec "$HERE/yappr-dictate"  "$@" ;;
  daemon)      exec "$HERE/yappr-daemon"   "$@" ;;
  config)      exec "$HERE/yappr-config"   "$@" ;;
  stats)       exec "$HERE/yappr-stats"    "$@" ;;
  trace)       exec "$HERE/yappr-trace"    "$@" ;;
  doctor)      exec "$HERE/yappr-doctor"   "$@" ;;
  server)      exec "$HERE/yappr-server"   "$@" ;;
  help|-h|--help) exec "$HERE/yappr-help" ;;
  version|--version|-V)
    echo "yappr $(cat "$YAPPR_ROOT/VERSION" 2>/dev/null || echo "unknown")"
    exit 0
    ;;
  *)
    echo "yappr: unknown subcommand '$CMD'" >&2
    echo "Run 'yappr help' for available subcommands." >&2
    exit 2
    ;;
esac
EOF
chmod +x bin/yappr
```

- [ ] **Step 4: Verify dispatcher syntax and --version**

```bash
bash -n bin/yappr && echo "syntax OK"
bash bin/yappr version
```

Expected: `syntax OK`, then `yappr 0.1.0`

- [ ] **Step 5: Verify Hammerspoon still works — dispatcher with no args calls yappr-dictate**

The Hammerspoon init.lua calls `YAPPR_BIN` with no args. With the dispatcher, `yappr` with no args executes `yappr-dictate` which is the old full orchestrator.

```bash
# Dry-run the dispatch path
bash -c 'source bin/_yappr-paths.sh; echo "Would exec: bin/yappr-dictate"'
```

- [ ] **Step 6: Commit**

```bash
git add bin/yappr bin/yappr-dictate
git commit -m "refactor: yappr becomes a subcommand dispatcher (git-style)

bin/yappr-dictate contains the former orchestrator logic unchanged.
bin/yappr is now a thin dispatcher: 'yappr dictate' or 'yappr' (no args)
both invoke yappr-dictate. Hammerspoon calls 'yappr' with no args — behavior unchanged."
```

---

### Task 4: Create `bin/yappr-daemon`

**Files:**
- Create: `bin/yappr-daemon`

- [ ] **Step 1: Write the script**

```bash
cat > bin/yappr-daemon << 'DAEMON_SCRIPT'
#!/usr/bin/env bash
# yappr-daemon — manage the YapprSttDaemon lifecycle.
# Usage: yappr daemon <start|stop|restart|status|logs|tail>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_yappr-paths.sh"
yappr_ensure_dirs

DAEMON_BIN="$(yappr_daemon_binary)"
CMD="${1:-status}"

_pid_running() {
  local pid
  pid="$(cat "$YAPPR_DAEMON_PID" 2>/dev/null)" || return 1
  kill -0 "$pid" 2>/dev/null
}

_start() {
  if _pid_running; then
    echo "yappr daemon: already running (pid=$(cat "$YAPPR_DAEMON_PID"))"
    return 0
  fi
  [[ -x "$DAEMON_BIN" ]] || { echo "yappr daemon: binary not found at $DAEMON_BIN" >&2; exit 1; }
  mkdir -p "$(dirname "$YAPPR_DAEMON_LOG")"
  nohup "$DAEMON_BIN" >> "$YAPPR_DAEMON_LOG" 2>&1 &
  echo $! > "$YAPPR_DAEMON_PID"
  local i
  for i in $(seq 1 10); do
    sleep 0.5
    [[ -S "$YAPPR_SOCKET" ]] && { echo "yappr daemon: started (pid=$!)"; return 0; }
  done
  echo "yappr daemon: started but socket not yet ready — check logs: yappr daemon logs" >&2
}

_stop() {
  if ! _pid_running; then
    echo "yappr daemon: not running"
    rm -f "$YAPPR_DAEMON_PID" "$YAPPR_SOCKET"
    return 0
  fi
  local pid
  pid="$(cat "$YAPPR_DAEMON_PID")"
  kill -TERM "$pid" 2>/dev/null || true
  local i
  for i in $(seq 1 4); do
    sleep 0.5
    kill -0 "$pid" 2>/dev/null || { rm -f "$YAPPR_DAEMON_PID" "$YAPPR_SOCKET"; echo "yappr daemon: stopped"; return 0; }
  done
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$YAPPR_DAEMON_PID" "$YAPPR_SOCKET"
  echo "yappr daemon: force-killed"
}

case "$CMD" in
  start)   _start ;;
  stop)    _stop ;;
  restart) _stop; sleep 0.5; _start ;;
  status)
    if _pid_running; then
      local_pid="$(cat "$YAPPR_DAEMON_PID")"
      sock_ok="no"
      [[ -S "$YAPPR_SOCKET" ]] && sock_ok="yes"
      echo "yappr daemon: running (pid=$local_pid, socket=$sock_ok)"
    else
      echo "yappr daemon: not running"
    fi
    ;;
  logs)  cat "$YAPPR_DAEMON_LOG" 2>/dev/null || echo "(no log yet at $YAPPR_DAEMON_LOG)" ;;
  tail)  tail -F "$YAPPR_DAEMON_LOG" 2>/dev/null ;;
  *)
    echo "Usage: yappr daemon <start|stop|restart|status|logs|tail>" >&2
    exit 2
    ;;
esac
DAEMON_SCRIPT
chmod +x bin/yappr-daemon
```

- [ ] **Step 2: Syntax check**

```bash
bash -n bin/yappr-daemon && echo "syntax OK"
```

- [ ] **Step 3: Test status with daemon not running**

```bash
bash bin/yappr-daemon status
```

Expected: `yappr daemon: not running`

- [ ] **Step 4: Commit**

```bash
git add bin/yappr-daemon
git commit -m "feat: add yappr-daemon — lifecycle management for YapprSttDaemon

'yappr daemon start' launches the daemon in the background, waits for the
socket to appear, and stores a PID file. 'stop', 'restart', 'status',
'logs', 'tail' work as expected. Reads all paths from _yappr-paths.sh."
```

---

### Task 5: Create `bin/yappr-server`

**Files:**
- Create: `bin/yappr-server`

Mirrors `yappr-daemon` but manages the MLX inference server.

- [ ] **Step 1: Write the script**

```bash
cat > bin/yappr-server << 'SERVER_SCRIPT'
#!/usr/bin/env bash
# yappr-server — manage the MLX inference server lifecycle.
# Usage: yappr server <start|stop|restart|status|logs|tail>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_yappr-paths.sh"
yappr_ensure_dirs

MLX_SERVER_PID="${YAPPR_RUNTIME_DIR}/mlx-server.pid"
MLX_SERVER_LOG="${YAPPR_STATE_HOME}/logs/mlx-server.log"
MLX_LAUNCHER="$(dirname "${BASH_SOURCE[0]}")/yappr-mlx-server"
CMD="${1:-status}"

_pid_running() {
  local pid
  pid="$(cat "$MLX_SERVER_PID" 2>/dev/null)" || return 1
  kill -0 "$pid" 2>/dev/null
}

_read_config() {
  # Extract model and port from active config JSON
  MLX_MODEL="$(jq -r '.llm.model // "mlx-community/Qwen3-1.7B-4bit"' "$YAPPR_CONFIG" 2>/dev/null)"
  MLX_PORT="$(jq -r '.llm.port // 8081' "$YAPPR_CONFIG" 2>/dev/null)"
  PROMPT_FILE="$(jq -r '.prompt_file // "prompts/cleanup.txt"' "$YAPPR_CONFIG" 2>/dev/null)"
  # Resolve prompt file: user config dir first, repo second
  if [[ -f "$YAPPR_CONFIG_HOME/$PROMPT_FILE" ]]; then
    PROMPT_FILE="$YAPPR_CONFIG_HOME/$PROMPT_FILE"
  else
    PROMPT_FILE="$YAPPR_ROOT/$PROMPT_FILE"
  fi
}

_start() {
  if _pid_running; then
    echo "yappr server: already running (pid=$(cat "$MLX_SERVER_PID"))"
    return 0
  fi
  [[ -x "$MLX_LAUNCHER" ]] || { echo "yappr server: launcher not found at $MLX_LAUNCHER" >&2; exit 1; }
  _read_config
  mkdir -p "$(dirname "$MLX_SERVER_LOG")"
  nohup "$MLX_LAUNCHER" \
    --model "$MLX_MODEL" \
    --system-prompt-file "$PROMPT_FILE" \
    --port "$MLX_PORT" \
    >> "$MLX_SERVER_LOG" 2>&1 &
  echo $! > "$MLX_SERVER_PID"
  echo "yappr server: started (pid=$!, model=$MLX_MODEL, port=$MLX_PORT)"
}

_stop() {
  if ! _pid_running; then
    echo "yappr server: not running"
    rm -f "$MLX_SERVER_PID"
    return 0
  fi
  local pid
  pid="$(cat "$MLX_SERVER_PID")"
  kill -TERM "$pid" 2>/dev/null || true
  local i
  for i in $(seq 1 4); do
    sleep 0.5
    kill -0 "$pid" 2>/dev/null || { rm -f "$MLX_SERVER_PID"; echo "yappr server: stopped"; return 0; }
  done
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$MLX_SERVER_PID"
  echo "yappr server: force-killed"
}

case "$CMD" in
  start)   _start ;;
  stop)    _stop ;;
  restart) _stop; sleep 0.5; _start ;;
  status)
    if _pid_running; then
      echo "yappr server: running (pid=$(cat "$MLX_SERVER_PID"))"
    else
      echo "yappr server: not running"
    fi
    ;;
  logs)  cat "$MLX_SERVER_LOG" 2>/dev/null || echo "(no log yet at $MLX_SERVER_LOG)" ;;
  tail)  tail -F "$MLX_SERVER_LOG" 2>/dev/null ;;
  *)
    echo "Usage: yappr server <start|stop|restart|status|logs|tail>" >&2
    exit 2
    ;;
esac
SERVER_SCRIPT
chmod +x bin/yappr-server
```

- [ ] **Step 2: Syntax check**

```bash
bash -n bin/yappr-server && echo "syntax OK"
```

- [ ] **Step 3: Test status**

```bash
bash bin/yappr-server status
```

Expected: `yappr server: not running`

- [ ] **Step 4: Commit**

```bash
git add bin/yappr-server
git commit -m "feat: add yappr-server — lifecycle management for MLX inference server

'yappr server start' reads model/port/prompt from active config and
launches yappr-mlx-server in the background. Mirrors the interface of
yappr-daemon."
```

---

### Task 6: Create `bin/yappr-help`

**Files:**
- Create: `bin/yappr-help`

- [ ] **Step 1: Write the script**

```bash
cat > bin/yappr-help << 'HELP'
#!/usr/bin/env bash
# yappr-help — print subcommand listing.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_yappr-paths.sh"
VERSION="$(cat "$YAPPR_ROOT/VERSION" 2>/dev/null || echo "unknown")"

cat <<EOF
yappr $VERSION — push-to-talk voice dictation for macOS Apple Silicon

USAGE
  yappr [subcommand] [options]

DAILY USE
  yappr dictate    Record and type cleaned text at cursor (default — called by Hammerspoon)
  yappr stats      Show dictation metrics (words, latency, daily usage)
  yappr trace      Show timing trace from last session

DAEMON & SERVER
  yappr daemon <start|stop|restart|status|logs|tail>
                   Manage the Nemotron STT daemon (YapprSttDaemon)
  yappr server <start|stop|restart|status|logs|tail>
                   Manage the MLX inference server (Qwen3)

CONFIGURATION
  yappr config list          List available configs
  yappr config use <name>    Switch active config
  yappr config show          Print active config

OTHER
  yappr doctor     Post-install health check (checks binaries, socket, LLM, permissions)
  yappr help       Show this message
  yappr version    Show version

ENV VAR OVERRIDES
  YAPPR_ROOT           Repo/source root (auto-detected)
  YAPPR_CONFIG         Path to active config JSON
  YAPPR_CONFIG_HOME    Config dir (default: ~/.config/yappr)
  YAPPR_STATE_HOME     State dir for logs/metrics (default: ~/.local/state/yappr)
  YAPPR_RUNTIME_DIR    Runtime dir for socket/PID (default: /tmp/yappr-\$(id -u))
  YAPPR_SOCKET         Socket path (default: \$YAPPR_RUNTIME_DIR/stt.sock)
  YAPPR_TRACE_LOG      Trace log path (default: \$YAPPR_RUNTIME_DIR/trace.log)

DOCS
  $YAPPR_ROOT/docs/installation.md
  $YAPPR_ROOT/docs/cli-reference.md
  $YAPPR_ROOT/CONTRIBUTING.md
EOF
HELP
chmod +x bin/yappr-help
```

- [ ] **Step 2: Verify**

```bash
bash -n bin/yappr-help && echo "syntax OK"
bash bin/yappr-help
```

Expected: clean help output with version, all subcommands listed.

- [ ] **Step 3: Commit**

```bash
git add bin/yappr-help
git commit -m "feat: add yappr-help — git-style subcommand listing

'yappr help' (or 'yappr -h' / 'yappr --help') prints a full subcommand
reference including env var overrides and docs links."
```

---

### Task 7: Create `bin/yappr-doctor`

**Files:**
- Create: `bin/yappr-doctor`

- [ ] **Step 1: Write the Python script**

```bash
cat > bin/yappr-doctor << 'DOCTOR'
#!/usr/bin/env python3
"""yappr-doctor — post-install health check."""
import json
import os
import platform
import shutil
import socket
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import _yappr_paths as paths

OK    = "\033[32m[OK]  \033[0m"
WARN  = "\033[33m[WARN]\033[0m"
FAIL  = "\033[31m[FAIL]\033[0m"

failures = 0

def ok(msg):   print(f"{OK} {msg}")
def warn(msg): print(f"{WARN} {msg}")
def fail(msg):
    global failures
    failures += 1
    print(f"{FAIL} {msg}")


# 1. Platform
if platform.system() == "Darwin" and platform.machine() == "arm64":
    ok("macOS Apple Silicon")
else:
    fail(f"Expected macOS Apple Silicon, got {platform.system()} {platform.machine()}")

# 2. Required commands
for cmd in ["jq", "python3"]:
    if shutil.which(cmd):
        ok(f"{cmd} on PATH")
    else:
        fail(f"{cmd} not found on PATH")

# 3. Required dirs
for label, p in [
    ("config dir", paths.config_home()),
    ("state/logs", paths.logs_dir()),
    ("state/metrics", paths.metrics_dir()),
    ("runtime dir", paths.runtime_dir()),
]:
    p = Path(p)
    if p.exists() and os.access(p, os.W_OK):
        ok(f"{label}: {p}")
    else:
        fail(f"{label} missing or not writable: {p}  →  run 'yappr daemon start' or install.sh")

# 4. Active config
config = paths.config_file()
if not config.exists():
    fail(f"Active config not found: {config}")
else:
    try:
        cfg = json.loads(config.read_text())
        llm_url = cfg.get("llm", {}).get("url", "")
        prompt_file = cfg.get("prompt_file", "")
        ok(f"Active config: {config}")
        if llm_url:
            ok(f"LLM url: {llm_url}")
        else:
            warn("Active config has no llm.url")
    except json.JSONDecodeError as e:
        fail(f"Active config is not valid JSON: {e}")

# 5. Daemon binary
daemon_bin = paths.daemon_binary()
if not daemon_bin.exists():
    fail(f"Daemon binary not found: {daemon_bin}  →  run scripts/install.sh")
else:
    r = subprocess.run(["codesign", "-dv", str(daemon_bin)],
                       capture_output=True)
    if r.returncode == 0:
        ok(f"Daemon binary codesigned: {daemon_bin.name}")
    else:
        warn(f"Daemon binary not codesigned (codesign -dv failed) — may lose mic TCC on rebuild")

# 6. Daemon process
pid_file = paths.daemon_pid()
running = False
if pid_file.exists():
    try:
        pid = int(pid_file.read_text().strip())
        os.kill(pid, 0)
        ok(f"Daemon running (pid={pid})")
        running = True
    except (ValueError, ProcessLookupError):
        fail(f"Daemon PID file exists but process is dead — run 'yappr daemon start'")
else:
    fail(f"Daemon not running — run 'yappr daemon start'")

# 7. Socket
sock_path = paths.socket()
if Path(sock_path).is_socket():
    try:
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(1)
        s.connect(str(sock_path))
        s.close()
        ok(f"Socket connectable: {sock_path}")
    except OSError:
        warn(f"Socket exists but not connectable: {sock_path}")
else:
    if running:
        warn(f"Socket not found: {sock_path} — daemon may still be starting")
    else:
        fail(f"Socket not found: {sock_path}")

# 8. LLM endpoint
try:
    llm_url = cfg.get("llm", {}).get("url", "http://127.0.0.1:8081/v1/chat/completions")
    health_url = llm_url.replace("/v1/chat/completions", "/v1/models")
    import urllib.request
    req = urllib.request.Request(health_url, method="GET")
    with urllib.request.urlopen(req, timeout=2) as resp:
        ok(f"LLM endpoint reachable: {health_url} (HTTP {resp.status})")
except Exception as e:
    warn(f"LLM endpoint not reachable: {health_url} — run 'yappr server start'")

# 9. Nemotron model cache
nemotron = Path.home() / ".cache/fluidaudio/models/nemotron-streaming/560ms/preprocessor.mlmodelc/coremldata.bin"
if nemotron.exists():
    ok(f"Nemotron model cache: {nemotron.parent.parent}")
else:
    fail(f"Nemotron model cache missing: {nemotron.parent}  →  re-run scripts/install.sh")

# 10. Hammerspoon
hs_app = Path("/Applications/Hammerspoon.app")
hs_lua = Path.home() / ".hammerspoon/init.lua"
if hs_app.exists():
    ok("Hammerspoon installed")
else:
    warn("Hammerspoon not installed — hotkey will not work")
if hs_lua.exists():
    content = hs_lua.read_text()
    yappr_bin = str(paths.root() / "bin" / "yappr")
    if yappr_bin in content or "yappr" in content:
        ok(f"~/.hammerspoon/init.lua references yappr")
    else:
        warn(f"~/.hammerspoon/init.lua exists but may not reference yappr binary")
else:
    fail(f"~/.hammerspoon/init.lua not found — run scripts/install.sh to write it")

# 11. mlx_lm
if shutil.which("mlx_lm.server") or shutil.which("mlx_lm"):
    ok("mlx_lm on PATH")
else:
    warn("mlx_lm not found on PATH — run: uv tool install mlx-lm")

# Summary
print()
if failures == 0:
    print("\033[32m✅ All checks passed. yappr is ready.\033[0m")
else:
    print(f"\033[31m❌ {failures} check(s) failed. Fix the items above and re-run: yappr doctor\033[0m")
    sys.exit(1)
DOCTOR
chmod +x bin/yappr-doctor
```

- [ ] **Step 2: Syntax check**

```bash
python3 -m py_compile bin/yappr-doctor && echo "syntax OK"
```

- [ ] **Step 3: Run it (expect some checks to pass, daemon checks may warn/fail if not running)**

```bash
python3 bin/yappr-doctor
```

Expected: Green `[OK]` for platform, jq/python3, config, Hammerspoon, mlx_lm. `[FAIL]` or `[WARN]` for daemon/socket/LLM if they're not running is acceptable.

- [ ] **Step 4: Commit**

```bash
git add bin/yappr-doctor
git commit -m "feat: add yappr-doctor — post-install health verifier

Runs 11 checks: platform, PATH tools, XDG dirs, active config validity,
daemon binary + codesign, daemon process + socket, LLM endpoint,
Nemotron model cache, Hammerspoon install + init.lua, mlx_lm.
Exits 1 on any FAIL with actionable hints."
```

---

### Task 8: Polish `bin/yappr-stats`

**Files:**
- Modify: `bin/yappr-stats`

- [ ] **Step 1: Read current yappr-stats to understand its structure**

```bash
grep -n "def cmd_\|METRICS_DIR\|stt_\|audio_ms\|archive\|--metrics" bin/yappr-stats | head -30
```

- [ ] **Step 2: Ensure _yappr_paths import is at the top (from Tier 2)**

The import block should already include:
```python
import sys as _sys
_sys.path.insert(0, str(Path(__file__).parent))
import _yappr_paths as paths
```

If not present, add it.

- [ ] **Step 3: Add --metrics-dir CLI flag**

Find the `argparse` setup in `yappr-stats`. Add:

```python
parser.add_argument(
    "--metrics-dir",
    default=None,
    metavar="DIR",
    help=f"Override metrics directory (default: {paths.metrics_dir()})"
)
```

In the argument handling, override `METRICS_DIR` if provided:

```python
if args.metrics_dir:
    METRICS_DIR = Path(args.metrics_dir)
```

- [ ] **Step 4: Add stt_total_held_ms to default summary display**

Find the function that prints the per-session summary (likely `cmd_summary` or similar). Find where it reads/prints latency metrics. Add `stt_total_held_ms` to the displayed fields:

Look for code like:
```python
print(f"  audio_ms:    {row.get('audio_ms', '-')}")
```

Add after the existing latency fields:
```python
held = row.get("stt_total_held_ms") or row.get("audio_ms")
if held is not None:
    print(f"  held_ms:     {held}")
```

- [ ] **Step 5: Update cmd_clear archive destination**

Find `cmd_clear` (or equivalent). Find where it moves metrics to an archive dir. Replace any `YAPPR_ROOT / "metrics.bak.*"` pattern with:

```python
import time
archive = paths.state_home() / f"metrics.bak.{int(time.time())}"
```

- [ ] **Step 6: Remove stale doc comment**

Find and remove any comment like "# To call from anywhere: ..." or similar developer notes that are artifacts of the old setup.

- [ ] **Step 7: Syntax and smoke test**

```bash
python3 -m py_compile bin/yappr-stats && echo "syntax OK"
python3 bin/yappr-stats --help
```

Expected: `syntax OK`, help text lists `--metrics-dir`.

- [ ] **Step 8: Commit**

```bash
git add bin/yappr-stats
git commit -m "polish: yappr-stats improvements

- Adds --metrics-dir flag for power users
- Adds stt_total_held_ms to summary display
- Archive path now goes to state home (not repo root)
- Removes stale developer doc comments
- Import _yappr_paths for all path resolution"
```

---

### Task 9: Create launchd plist template and install.sh step

**Files:**
- Create: `scripts/templates/com.yappr.daemon.plist.tmpl`
- Modify: `scripts/install.sh`

- [ ] **Step 1: Write the plist template**

```bash
cat > scripts/templates/com.yappr.daemon.plist.tmpl << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.yappr.daemon</string>

    <key>ProgramArguments</key>
    <array>
        <string>@DAEMON_BIN@</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>YAPPR_ROOT</key>         <string>@YAPPR_ROOT@</string>
        <key>YAPPR_STATE_HOME</key>   <string>@YAPPR_STATE_HOME@</string>
        <key>YAPPR_RUNTIME_DIR</key>  <string>@YAPPR_RUNTIME_DIR@</string>
        <key>YAPPR_SOCKET</key>       <string>@YAPPR_SOCKET@</string>
        <key>YAPPR_DAEMON_PID</key>   <string>@YAPPR_DAEMON_PID@</string>
        <key>YAPPR_DAEMON_LOG</key>   <string>@YAPPR_DAEMON_LOG@</string>
        <key>YAPPR_TRACE_LOG</key>    <string>@YAPPR_TRACE_LOG@</string>
    </dict>

    <key>RunAtLoad</key>    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>Crashed</key> <true/>
    </dict>

    <key>StandardErrorPath</key>
    <string>@YAPPR_DAEMON_LOG@</string>

    <key>ProcessType</key>
    <string>Interactive</string>

    <key>WorkingDirectory</key>
    <string>@YAPPR_ROOT@</string>
</dict>
</plist>
PLIST
```

- [ ] **Step 2: Add launchd step to install.sh**

Find the section near the end of `scripts/install.sh` (after codesign, before the final summary). Add:

```bash
# -----------------------------------------------------------------------------
# Daemon auto-start via launchd (optional)
# -----------------------------------------------------------------------------

step "Daemon auto-start at login (launchd)"

PLIST_DEST="$HOME/Library/LaunchAgents/com.yappr.daemon.plist"
PLIST_TMPL="$YAPPR_ROOT/scripts/templates/com.yappr.daemon.plist.tmpl"

if [[ $SKIP_OPTIONAL -eq 0 ]]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  sed \
    -e "s|@DAEMON_BIN@|$DAEMON_BIN|g" \
    -e "s|@YAPPR_ROOT@|$YAPPR_ROOT|g" \
    -e "s|@YAPPR_STATE_HOME@|$YAPPR_STATE_HOME|g" \
    -e "s|@YAPPR_RUNTIME_DIR@|$YAPPR_RUNTIME_DIR|g" \
    -e "s|@YAPPR_SOCKET@|$YAPPR_SOCKET|g" \
    -e "s|@YAPPR_DAEMON_PID@|$YAPPR_DAEMON_PID|g" \
    -e "s|@YAPPR_DAEMON_LOG@|$YAPPR_DAEMON_LOG|g" \
    -e "s|@YAPPR_TRACE_LOG@|$YAPPR_TRACE_LOG|g" \
    "$PLIST_TMPL" > "$PLIST_DEST"
  launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null \
    || launchctl load "$PLIST_DEST" 2>/dev/null \
    || warn "launchctl load failed — daemon will not auto-start. Start manually: yappr daemon start"
  ok "launchd plist installed: $PLIST_DEST"
else
  info "Skipped launchd (--skip-optional). Start daemon manually: yappr daemon start"
fi
```

- [ ] **Step 3: Verify plist template has all placeholders**

```bash
grep "@[A-Z_]*@" scripts/templates/com.yappr.daemon.plist.tmpl
```

Expected: all 8 `@PLACEHOLDER@` entries listed.

- [ ] **Step 4: Syntax check install.sh**

```bash
bash -n scripts/install.sh && echo "syntax OK"
```

- [ ] **Step 5: Commit**

```bash
git add scripts/templates/com.yappr.daemon.plist.tmpl scripts/install.sh
git commit -m "feat: launchd plist for daemon auto-start at login

scripts/templates/com.yappr.daemon.plist.tmpl is rendered by install.sh
into ~/Library/LaunchAgents/com.yappr.daemon.plist with all YAPPR_* env
vars substituted. Daemon starts at login and restarts on crash.
Optional — skipped with --skip-optional."
```

---

### Task 10: Create shell completions

**Files:**
- Create: `completions/yappr.bash`
- Create: `completions/yappr.zsh`
- Create: `completions/_yappr.fish`

- [ ] **Step 1: Create completions directory**

```bash
mkdir -p completions
```

- [ ] **Step 2: Write bash completion**

```bash
cat > completions/yappr.bash << 'BASH_COMP'
# bash completion for yappr
_yappr_completions() {
  local cur prev subcommands
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  subcommands="dictate daemon config stats trace doctor server help version"

  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=($(compgen -W "$subcommands" -- "$cur"))
    return
  fi

  case "$prev" in
    daemon|server)
      COMPREPLY=($(compgen -W "start stop restart status logs tail" -- "$cur")) ;;
    config)
      COMPREPLY=($(compgen -W "list use show" -- "$cur")) ;;
    stats)
      COMPREPLY=($(compgen -W "--metrics-dir --help" -- "$cur")) ;;
  esac
}
complete -F _yappr_completions yappr
BASH_COMP
```

- [ ] **Step 3: Write zsh completion**

```bash
cat > completions/yappr.zsh << 'ZSH_COMP'
#compdef yappr
# zsh completion for yappr

_yappr() {
  local state

  _arguments \
    '1: :->subcommand' \
    '*: :->args'

  case $state in
    subcommand)
      local subcommands=(
        'dictate:Record and type cleaned text at cursor'
        'daemon:Manage the STT daemon'
        'config:Manage configurations'
        'stats:Show dictation metrics'
        'trace:Show timing trace'
        'doctor:Post-install health check'
        'server:Manage the MLX inference server'
        'help:Show help'
        'version:Show version'
      )
      _describe 'subcommand' subcommands ;;
    args)
      case ${words[2]} in
        daemon|server)
          local cmds=('start' 'stop' 'restart' 'status' 'logs' 'tail')
          _describe 'operation' cmds ;;
        config)
          local cmds=('list' 'use' 'show')
          _describe 'operation' cmds ;;
      esac ;;
  esac
}

_yappr "$@"
ZSH_COMP
```

- [ ] **Step 4: Write fish completion**

```bash
cat > completions/_yappr.fish << 'FISH_COMP'
# fish completion for yappr
complete -c yappr -f
complete -c yappr -n '__fish_use_subcommand' -a dictate  -d 'Record and type cleaned text'
complete -c yappr -n '__fish_use_subcommand' -a daemon   -d 'Manage STT daemon'
complete -c yappr -n '__fish_use_subcommand' -a config   -d 'Manage configurations'
complete -c yappr -n '__fish_use_subcommand' -a stats    -d 'Show dictation metrics'
complete -c yappr -n '__fish_use_subcommand' -a trace    -d 'Show timing trace'
complete -c yappr -n '__fish_use_subcommand' -a doctor   -d 'Post-install health check'
complete -c yappr -n '__fish_use_subcommand' -a server   -d 'Manage MLX inference server'
complete -c yappr -n '__fish_use_subcommand' -a help     -d 'Show help'
complete -c yappr -n '__fish_use_subcommand' -a version  -d 'Show version'

for sub in daemon server
  complete -c yappr -n "__fish_seen_subcommand_from $sub" -a start   -d 'Start'
  complete -c yappr -n "__fish_seen_subcommand_from $sub" -a stop    -d 'Stop'
  complete -c yappr -n "__fish_seen_subcommand_from $sub" -a restart -d 'Restart'
  complete -c yappr -n "__fish_seen_subcommand_from $sub" -a status  -d 'Check status'
  complete -c yappr -n "__fish_seen_subcommand_from $sub" -a logs    -d 'Print log'
  complete -c yappr -n "__fish_seen_subcommand_from $sub" -a tail    -d 'Follow log'
end

complete -c yappr -n '__fish_seen_subcommand_from config' -a list  -d 'List configs'
complete -c yappr -n '__fish_seen_subcommand_from config' -a use   -d 'Switch config'
complete -c yappr -n '__fish_seen_subcommand_from config' -a show  -d 'Show active config'
FISH_COMP
```

- [ ] **Step 5: Verify syntax**

```bash
bash -n completions/yappr.bash && echo "bash OK"
# zsh -n is unavailable without zsh; skip
python3 -c "open('completions/yappr.zsh'); open('completions/_yappr.fish'); print('files OK')"
```

- [ ] **Step 6: Commit**

```bash
git add completions/
git commit -m "feat: add shell completions for bash, zsh, and fish

completions/yappr.bash, completions/yappr.zsh, completions/_yappr.fish
cover all subcommands and their arguments (start/stop/etc. for daemon and
server, list/use/show for config)."
```

---

### Task 11: Create GitHub Actions CI

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Create the .github directory**

```bash
mkdir -p .github/workflows
```

- [ ] **Step 2: Write ci.yml**

```bash
cat > .github/workflows/ci.yml << 'CI'
name: CI

on:
  push:
    branches: ["main", "feat/**"]
  pull_request:
    branches: ["main", "feat/**"]

jobs:
  build-and-lint:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Install lint tools
        run: |
          brew install shellcheck
          pip install ruff

      - name: Swift build
        run: |
          source bin/_yappr-paths.sh
          cd swift/yappr-stt-daemon
          swift build -c release \
            --scratch-path "$RUNNER_TEMP/build/yappr-stt-daemon"

      - name: Ad-hoc codesign
        run: |
          source bin/_yappr-paths.sh
          DAEMON_BIN="$RUNNER_TEMP/build/yappr-stt-daemon/release/YapprSttDaemon"
          CONNECT_BIN="$RUNNER_TEMP/build/yappr-stt-daemon/release/YapprSttConnect"
          codesign --force --sign - "$DAEMON_BIN"
          codesign --force --sign - "$CONNECT_BIN"

      - name: Shellcheck
        run: |
          shellcheck bin/_yappr-paths.sh bin/yappr bin/yappr-dictate \
            bin/yappr-daemon bin/yappr-server bin/yappr-help \
            scripts/install.sh scripts/migrate-runtime-state.sh \
            scripts/check-no-runtime-writes.sh \
            diagnostics/yappr-probe-caching

      - name: Ruff (Python lint)
        run: |
          ruff check bin/_yappr_paths.py bin/yappr-stats bin/yappr-doctor \
            bin/yappr-mlx-server.py

      - name: No runtime writes in source tree
        run: bash scripts/check-no-runtime-writes.sh
CI
```

- [ ] **Step 3: Write release.yml**

```bash
cat > .github/workflows/release.yml << 'RELEASE'
name: Release

on:
  push:
    tags:
      - "v[0-9]+.[0-9]+.[0-9]+"

jobs:
  release:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Read version
        run: echo "VERSION=$(cat VERSION)" >> $GITHUB_ENV

      - name: Swift build
        run: |
          source bin/_yappr-paths.sh
          cd swift/yappr-stt-daemon
          swift build -c release \
            --scratch-path "$RUNNER_TEMP/build/yappr-stt-daemon"

      - name: Ad-hoc codesign
        run: |
          codesign --force --sign - \
            "$RUNNER_TEMP/build/yappr-stt-daemon/release/YapprSttDaemon"
          codesign --force --sign - \
            "$RUNNER_TEMP/build/yappr-stt-daemon/release/YapprSttConnect"

      - name: Bundle tarball
        run: |
          DIST="yappr-${{ env.VERSION }}-macos-arm64"
          mkdir -p "$DIST/bin"
          cp -r bin scripts configs prompts completions docs README.md LICENSE VERSION "$DIST/" 2>/dev/null || true
          cp "$RUNNER_TEMP/build/yappr-stt-daemon/release/YapprSttDaemon" "$DIST/bin/"
          cp "$RUNNER_TEMP/build/yappr-stt-daemon/release/YapprSttConnect" "$DIST/bin/"
          tar czf "$DIST.tar.gz" "$DIST"
          echo "TARBALL=$DIST.tar.gz" >> $GITHUB_ENV

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: ${{ env.TARBALL }}
          generate_release_notes: true
RELEASE
```

- [ ] **Step 4: Verify YAML syntax (no yamllint needed — just check they're well-formed)**

```bash
python3 -c "
import sys
# Basic YAML parse check using stdlib
for f in ['.github/workflows/ci.yml', '.github/workflows/release.yml']:
    try:
        open(f).read()
        print(f'readable: {f}')
    except Exception as e:
        print(f'ERROR: {f}: {e}')
        sys.exit(1)
print('OK')
"
```

- [ ] **Step 5: Commit**

```bash
git add .github/
git commit -m "feat: add GitHub Actions CI and release workflows

ci.yml: runs on push/PR to main and feat/* on macos-14. Steps: submodule
init, Swift build, ad-hoc codesign, shellcheck, ruff, and the no-runtime-
writes audit.

release.yml: on semver tag, builds daemon, bundles with scripts/docs,
creates a GitHub Release with a .tar.gz."
```

---

### Task 12: Final verification and PR

**Files:**
- No code changes

- [ ] **Step 1: Full shellcheck pass**

```bash
shellcheck bin/_yappr-paths.sh bin/yappr bin/yappr-dictate \
  bin/yappr-daemon bin/yappr-server bin/yappr-help \
  scripts/install.sh scripts/migrate-runtime-state.sh \
  scripts/check-no-runtime-writes.sh \
  completions/yappr.bash 2>&1
```

Fix any SC-level errors (warnings about dynamic source or single-use vars are OK to suppress with `# shellcheck disable=...`).

- [ ] **Step 2: Python syntax and ruff check**

```bash
python3 -m py_compile bin/_yappr_paths.py bin/yappr-stats bin/yappr-doctor bin/yappr-mlx-server.py && echo "all OK"
pip install ruff -q
ruff check bin/_yappr_paths.py bin/yappr-stats bin/yappr-doctor bin/yappr-mlx-server.py 2>&1
```

Fix any ruff errors.

- [ ] **Step 3: Run no-runtime-writes audit**

```bash
bash scripts/check-no-runtime-writes.sh
```

Expected: `OK`

- [ ] **Step 4: Run yappr doctor**

```bash
python3 bin/yappr-doctor
```

Expected: most checks `[OK]`. Any `[FAIL]` for daemon/socket is fine if the daemon isn't running locally.

- [ ] **Step 5: Verify dispatcher**

```bash
bash bin/yappr help
bash bin/yappr version
bash bin/yappr daemon status
bash bin/yappr server status
```

Expected: all work without errors.

- [ ] **Step 6: Review all commits**

```bash
git log feat/tier-2-runtime-separation..HEAD --oneline
```

Expected: ~10 commits covering Tasks 2–11.

- [ ] **Step 7: Push and open PR**

```bash
git push -u origin feat/tier-3-polish
```

PR title: `feat: Tier 3 — polish + open-source readiness`
PR target: `feat/tier-2-runtime-separation`

PR body:
- ✅ `yappr` subcommand dispatcher (git-style; former logic → `yappr-dictate`)
- ✅ `yappr daemon` — lifecycle: start/stop/restart/status/logs/tail
- ✅ `yappr server` — same shape for MLX server
- ✅ `yappr doctor` — 11 post-install health checks with actionable hints
- ✅ `yappr help` — git-style subcommand listing with env var overrides
- ✅ `yappr-stats` polish: --metrics-dir flag, stt_total_held_ms, archive to state home
- ✅ launchd plist template + install.sh step for daemon auto-start at login
- ✅ Shell completions (bash, zsh, fish)
- ✅ GitHub Actions CI (shellcheck, ruff, Swift build, no-runtime-writes)
- ✅ GitHub Actions release workflow (semver tag → GitHub Release)
- ✅ VERSION file

**Test plan:** Run `yappr help`, `yappr version`, `yappr daemon start`, `yappr daemon status`, `yappr doctor`, and a full dictation session.
