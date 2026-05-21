# Tier 2 — Runtime Separation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move all runtime writes (logs, metrics, sockets, PID files, trace logs) out of the source tree and into XDG-compliant directories. After this tier, `git status` is clean both after install and after a full day of dictation sessions.

**Architecture:** Introduce a single source-of-truth path-resolution layer — `bin/_yappr-paths.sh` for bash and `bin/_yappr_paths.py` for Python — that computes every runtime path from env vars with XDG-based defaults. All scripts source/import this layer. The Swift daemon reads the same vars via `ProcessInfo.processInfo.environment`. A migration script handles existing logs/metrics. A CI-ready audit script verifies no new runtime writes sneak back into the source tree.

**Tech Stack:** bash, Python 3, Swift (ProcessInfo), git, XDG directory spec

**Branch:** `feat/tier-2-runtime-separation` stacked on `feat/tier-1-install-fixes`
**PR target:** `feat/tier-1-install-fixes` (merge Tier 1 first, then this merges into it)

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `bin/_yappr-paths.sh` | Create | Bash path-resolution layer — sourced by all bash scripts |
| `bin/_yappr_paths.py` | Create | Python path-resolution layer — imported by Python scripts |
| `bin/yappr` | Modify | Source `_yappr-paths.sh`; use `$YAPPR_CONFIG` and `$YAPPR_STATE_HOME` for log/metric paths |
| `bin/yappr-config` | Modify | Source `_yappr-paths.sh`; search user config dir first, repo dir second |
| `bin/yappr-stats` | Modify | Import `_yappr_paths.py`; remove hardcoded METRICS_DIR |
| `bin/yappr-trace` | Modify | Import `_yappr_paths.py`; use `paths.trace_log()` |
| `bin/yappr-mlx-server` | Modify | Source `_yappr-paths.sh` (no path changes needed, but ensures env vars set) |
| `diagnostics/yappr-probe-caching` | Modify | Source `_yappr-paths.sh`; use `$YAPPR_CONFIG_HOME` for prompt file |
| `swift/yappr-stt-daemon/Sources/YapprSttDaemon/Daemon.swift` | Modify | Read `YAPPR_SOCKET`, `YAPPR_RUNTIME_DIR`, `YAPPR_DAEMON_PID` from env |
| `swift/yappr-stt-daemon/Sources/YapprSttDaemon/Trace.swift` | Modify | Read `YAPPR_TRACE_LOG` from env |
| `swift/yappr-stt-daemon/Sources/YapprSttConnect/main.swift` | Modify | Read `YAPPR_SOCKET` from env |
| `scripts/install.sh` | Modify | Add user config dir seeding step; add `--scratch-path` to Swift builds |
| `scripts/migrate-runtime-state.sh` | Create | One-time migration: move existing repo logs/metrics to XDG dirs |
| `scripts/check-no-runtime-writes.sh` | Create | CI audit: fails if any script writes inside `$YAPPR_ROOT` |
| `.gitignore` | Modify | Remove `logs/`, `metrics/`, `recordings/`, `metrics.bak.*/`, `.build/` lines |

---

### Task 1: Create branch from tier-1

**Files:**
- No file changes

- [ ] **Step 1: Ensure tier-1 is up to date, then create tier-2 branch**

```bash
cd /Users/matteociccozzi/yappr
git checkout feat/tier-1-install-fixes
git pull origin feat/tier-1-install-fixes 2>/dev/null || true
git checkout -b feat/tier-2-runtime-separation
```

Expected: `Switched to a new branch 'feat/tier-2-runtime-separation'`

- [ ] **Step 2: Confirm base is correct**

```bash
git log --oneline -8
```

Expected: all Tier 1 commits visible, no Tier 2 commits yet.

---

### Task 2: Create `bin/_yappr-paths.sh` — the bash path helper

**Files:**
- Create: `bin/_yappr-paths.sh`

This is the foundational file for all of Tier 2. Every env var in the XDG table lives here.

- [ ] **Step 1: Write the file**

```bash
cat > bin/_yappr-paths.sh << 'EOF'
# _yappr-paths.sh — source this file (do not execute directly).
# Sets and exports all YAPPR_* path env vars with XDG-based defaults.
# Every variable is overridable by the caller's environment.

# Repo root: prefer env var, fall back to self-detection from this file's location.
YAPPR_ROOT="${YAPPR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export YAPPR_ROOT

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

# Config resolution: user dir first, repo shipped defaults second
YAPPR_CONFIG="${YAPPR_CONFIG:-$YAPPR_CONFIG_HOME/configs/active.json}"
if [[ ! -f "$YAPPR_CONFIG" ]]; then
  YAPPR_CONFIG="$YAPPR_ROOT/configs/active.json"
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
  echo "$YAPPR_BUILD_DIR/yappr-stt-daemon/release/YapprSttConnect"
}

# Path to the built YapprSttDaemon binary
yappr_daemon_binary() {
  echo "$YAPPR_BUILD_DIR/yappr-stt-daemon/release/YapprSttDaemon"
}
EOF
chmod +x bin/_yappr-paths.sh
```

- [ ] **Step 2: Verify syntax and spot-check key variables**

```bash
bash -n bin/_yappr-paths.sh && echo "syntax OK"
bash -c 'source bin/_yappr-paths.sh; echo "ROOT=$YAPPR_ROOT"; echo "STATE=$YAPPR_STATE_HOME"; echo "RUNTIME=$YAPPR_RUNTIME_DIR"; echo "SOCKET=$YAPPR_SOCKET"'
```

Expected:
```
syntax OK
ROOT=/Users/matteociccozzi/yappr
STATE=/Users/matteociccozzi/.local/state/yappr
RUNTIME=/tmp/yappr-<uid>
SOCKET=/tmp/yappr-<uid>/stt.sock
```

- [ ] **Step 3: Verify all helper functions are defined**

```bash
bash -c 'source bin/_yappr-paths.sh; yappr_ensure_dirs; echo "dirs OK"; yappr_metric_path; yappr_log_path; yappr_connect_binary'
```

Expected: `dirs OK` followed by three paths containing expected segments (no errors).

- [ ] **Step 4: Commit**

```bash
git add bin/_yappr-paths.sh
git commit -m "feat: add bin/_yappr-paths.sh — single source of truth for all YAPPR_* paths

Every runtime path is now defined once: XDG-based defaults, all
overridable via env var. Bash scripts source this file; Python scripts
import the equivalent _yappr_paths.py (next commit). Swift daemon reads
the same vars via ProcessInfo."
```

---

### Task 3: Create `bin/_yappr_paths.py` — the Python path helper

**Files:**
- Create: `bin/_yappr_paths.py`

- [ ] **Step 1: Write the file**

```bash
cat > bin/_yappr_paths.py << 'EOF'
"""
_yappr_paths.py — import this module from Python scripts.
Provides path resolution matching bin/_yappr-paths.sh exactly.
Every path is overridable via the corresponding YAPPR_* env var.
"""
import os
import subprocess
from pathlib import Path


def _xdg(var: str, default: str) -> Path:
    return Path(os.environ.get(var) or default)


def _uid() -> str:
    return str(os.getuid())


def root() -> Path:
    env = os.environ.get("YAPPR_ROOT")
    if env:
        return Path(env)
    # Self-detect: this file lives at <root>/bin/_yappr_paths.py
    return Path(__file__).resolve().parent.parent


def config_home() -> Path:
    env = os.environ.get("YAPPR_CONFIG_HOME")
    if env:
        return Path(env)
    xdg = os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))
    return Path(xdg) / "yappr"


def data_home() -> Path:
    env = os.environ.get("YAPPR_DATA_HOME")
    if env:
        return Path(env)
    xdg = os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local" / "share"))
    return Path(xdg) / "yappr"


def state_home() -> Path:
    env = os.environ.get("YAPPR_STATE_HOME")
    if env:
        return Path(env)
    xdg = os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local" / "state"))
    return Path(xdg) / "yappr"


def cache_home() -> Path:
    env = os.environ.get("YAPPR_CACHE_HOME")
    if env:
        return Path(env)
    xdg = os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))
    return Path(xdg) / "yappr"


def runtime_dir() -> Path:
    env = os.environ.get("YAPPR_RUNTIME_DIR")
    if env:
        return Path(env)
    xdg = os.environ.get("XDG_RUNTIME_DIR")
    if xdg:
        return Path(xdg)
    return Path(f"/tmp/yappr-{_uid()}")


def socket() -> Path:
    return Path(os.environ.get("YAPPR_SOCKET") or runtime_dir() / "stt.sock")


def trace_log() -> Path:
    return Path(os.environ.get("YAPPR_TRACE_LOG") or runtime_dir() / "trace.log")


def daemon_log() -> Path:
    return Path(os.environ.get("YAPPR_DAEMON_LOG") or state_home() / "logs" / "daemon.log")


def daemon_pid() -> Path:
    return Path(os.environ.get("YAPPR_DAEMON_PID") or runtime_dir() / "daemon.pid")


def metrics_dir() -> Path:
    return Path(os.environ.get("YAPPR_METRICS_DIR") or state_home() / "metrics")


def logs_dir() -> Path:
    return Path(os.environ.get("YAPPR_LOGS_DIR") or state_home() / "logs")


def config_file() -> Path:
    env = os.environ.get("YAPPR_CONFIG")
    if env:
        return Path(env)
    user = config_home() / "configs" / "active.json"
    if user.exists():
        return user
    return root() / "configs" / "active.json"


def build_dir() -> Path:
    return Path(os.environ.get("YAPPR_BUILD_DIR") or data_home() / "build")


def connect_binary() -> Path:
    return build_dir() / "yappr-stt-daemon" / "release" / "YapprSttConnect"


def daemon_binary() -> Path:
    return build_dir() / "yappr-stt-daemon" / "release" / "YapprSttDaemon"


def ensure_dirs() -> None:
    """Create all runtime and state dirs yappr needs."""
    import stat
    logs_dir().mkdir(parents=True, exist_ok=True)
    metrics_dir().mkdir(parents=True, exist_ok=True)
    rd = runtime_dir()
    rd.mkdir(parents=True, exist_ok=True)
    rd.chmod(stat.S_IRWXU)  # 0700
EOF
```

- [ ] **Step 2: Verify the module imports cleanly and produces correct paths**

```bash
python3 -c "
import sys
sys.path.insert(0, 'bin')
import _yappr_paths as paths
print('root:', paths.root())
print('state_home:', paths.state_home())
print('runtime_dir:', paths.runtime_dir())
print('socket:', paths.socket())
print('metrics_dir:', paths.metrics_dir())
assert str(paths.root()) == '/Users/matteociccozzi/yappr', f'Wrong root: {paths.root()}'
print('OK')
"
```

Expected: correct paths printed and `OK`.

- [ ] **Step 3: Verify env var overrides work**

```bash
python3 -c "
import sys, os
os.environ['YAPPR_STATE_HOME'] = '/tmp/test-yappr-state'
sys.path.insert(0, 'bin')
import _yappr_paths as paths
assert str(paths.metrics_dir()) == '/tmp/test-yappr-state/metrics', paths.metrics_dir()
print('override OK')
"
```

Expected: `override OK`

- [ ] **Step 4: Commit**

```bash
git add bin/_yappr_paths.py
git commit -m "feat: add bin/_yappr_paths.py — Python counterpart to _yappr-paths.sh

Identical path resolution logic in Python. All yappr Python scripts will
import this module instead of computing paths inline. Env var overrides
work identically to the bash version."
```

---

### Task 4: Update `bin/yappr` to use path helpers

**Files:**
- Modify: `bin/yappr`

- [ ] **Step 1: Find the current path-related lines**

```bash
grep -n "YAPPR_ROOT\|LOGS_DIR\|METRIC\|LOG_FILE\|socket\|SOCKET" bin/yappr | head -30
```

Note the line numbers — you'll need them for the edits below.

- [ ] **Step 2: Add source of _yappr-paths.sh near the top**

Find the line `set -euo pipefail` (or similar) near the top of `bin/yappr`. Immediately after that block (after the initial variable setup), add:

```bash
# Load path helpers (sets YAPPR_ROOT, YAPPR_STATE_HOME, YAPPR_RUNTIME_DIR, etc.)
source "$(dirname "${BASH_SOURCE[0]}")/_yappr-paths.sh"
yappr_ensure_dirs
```

- [ ] **Step 3: Replace the hardcoded log and metric path computation**

Find lines like:
```bash
LOG_DIR="$YAPPR_ROOT/logs"
LOG_FILE="$LOG_DIR/$(date +%Y%m%d-%H%M%S).log"
```
or similar. Replace with:
```bash
LOG_FILE="$(yappr_log_path)"
METRIC_FILE="$(yappr_metric_path)"
```

Also find any reference to `/tmp/yappr-stt.sock` and replace with `$YAPPR_SOCKET`.

- [ ] **Step 4: Verify syntax**

```bash
bash -n bin/yappr && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 5: Smoke test — invoke with no daemon running to verify path setup**

```bash
YAPPR_STATE_HOME=/tmp/test-yappr-state bash -c '
  source bin/_yappr-paths.sh
  yappr_ensure_dirs
  echo "LOG=$(yappr_log_path)"
  echo "METRIC=$(yappr_metric_path)"
  echo "SOCKET=$YAPPR_SOCKET"
  ls /tmp/test-yappr-state/logs /tmp/test-yappr-state/metrics
'
```

Expected: paths under `/tmp/test-yappr-state/`, dirs created, no errors.

```bash
rm -rf /tmp/test-yappr-state
```

- [ ] **Step 6: Commit**

```bash
git add bin/yappr
git commit -m "refactor: yappr sources _yappr-paths.sh for all runtime paths

Log files now go to \$YAPPR_STATE_HOME/logs/. Metrics go to
\$YAPPR_STATE_HOME/metrics/. Socket path reads from \$YAPPR_SOCKET.
No logic changes — pure path routing."
```

---

### Task 5: Update `bin/yappr-config` for user config dir

**Files:**
- Modify: `bin/yappr-config`

- [ ] **Step 1: Find current CONFIG_DIR setup**

```bash
grep -n "CONFIG_DIR\|YAPPR_ROOT\|configs/" bin/yappr-config | head -20
```

- [ ] **Step 2: Add source of _yappr-paths.sh and update config resolution**

After `set -euo pipefail`, add:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/_yappr-paths.sh"
```

Find the line that sets `CONFIG_DIR` (something like `CONFIG_DIR="$YAPPR_ROOT/configs"`). Replace it with:

```bash
# User config dir takes precedence; fall back to shipped configs in repo
USER_CONFIG_DIR="$YAPPR_CONFIG_HOME/configs"
SHIP_CONFIG_DIR="$YAPPR_ROOT/configs"
CONFIG_DIR="$USER_CONFIG_DIR"
```

For the `use` subcommand — where it creates/updates the `active.json` symlink — update to target `$USER_CONFIG_DIR/active.json`. If `$USER_CONFIG_DIR` doesn't exist yet, create it and seed from ship dir:

```bash
# In the 'use' command handler:
if [[ ! -d "$USER_CONFIG_DIR" ]]; then
  mkdir -p "$USER_CONFIG_DIR"
  cp "$SHIP_CONFIG_DIR"/*.json "$USER_CONFIG_DIR/" 2>/dev/null || true
fi
```

- [ ] **Step 3: Verify syntax**

```bash
bash -n bin/yappr-config && echo "syntax OK"
```

- [ ] **Step 4: Commit**

```bash
git add bin/yappr-config
git commit -m "refactor: yappr-config reads user config from \$YAPPR_CONFIG_HOME

'yappr config use <name>' now manages symlinks in
\$YAPPR_CONFIG_HOME/configs/ rather than the repo's configs/ dir.
Falls back to shipped configs in the repo. Seeds user config dir on
first use."
```

---

### Task 6: Update Python scripts to use `_yappr_paths.py`

**Files:**
- Modify: `bin/yappr-stats`
- Modify: `bin/yappr-trace` (if it exists as Python)
- Modify: `diagnostics/yappr-probe-caching` (if Python portions exist)

- [ ] **Step 1: Update bin/yappr-stats**

Find `bin/yappr-stats`. At the top of the imports, add:

```python
import sys as _sys
_sys.path.insert(0, str(__file__).rsplit("/", 1)[0])  # ensure bin/ on path
import _yappr_paths as paths
```

Find the lines that compute `YAPPR_ROOT` and `METRICS_DIR`. The current version from Tier 1 looks like:

```python
_self = Path(__file__).resolve()
YAPPR_ROOT = Path(os.environ.get("YAPPR_ROOT") or _self.parent.parent)
METRICS_DIR = Path(os.environ.get("YAPPR_METRICS_DIR") or YAPPR_ROOT / "metrics")
```

Replace with:

```python
YAPPR_ROOT = paths.root()
METRICS_DIR = Path(os.environ.get("YAPPR_METRICS_DIR") or paths.metrics_dir())
```

Also find the archive path (used in `cmd_clear`). Replace any `YAPPR_ROOT / "metrics.bak.*"` with `paths.state_home() / f"metrics.bak.{int(time.time())}"`.

- [ ] **Step 2: Check if bin/yappr-trace exists and update if so**

```bash
ls bin/yappr-trace 2>/dev/null && echo "exists" || echo "does not exist"
```

If it exists and is Python, add the same import block and replace any hardcoded log/trace paths with `paths.trace_log()`.

- [ ] **Step 3: Syntax check all modified Python files**

```bash
python3 -m py_compile bin/yappr-stats && echo "yappr-stats OK"
```

- [ ] **Step 4: Smoke test yappr-stats path resolution**

```bash
python3 -c "
import sys
sys.path.insert(0, 'bin')
import _yappr_paths as paths
print('metrics_dir:', paths.metrics_dir())
assert 'metrics' in str(paths.metrics_dir())
print('OK')
"
```

- [ ] **Step 5: Commit**

```bash
git add bin/yappr-stats bin/yappr-trace 2>/dev/null; git add diagnostics/ 2>/dev/null; true
git commit -m "refactor: Python scripts import _yappr_paths for path resolution

yappr-stats now reads metrics from \$YAPPR_STATE_HOME/metrics/ via
_yappr_paths.py. Archive destination moved to state home. Removes
remaining hardcoded YAPPR_ROOT assumptions from Python layer."
```

---

### Task 7: Update Swift daemon to read paths from environment

**Files:**
- Modify: `swift/yappr-stt-daemon/Sources/YapprSttDaemon/Daemon.swift`
- Modify: `swift/yappr-stt-daemon/Sources/YapprSttDaemon/Trace.swift` (if exists)
- Modify: `swift/yappr-stt-daemon/Sources/YapprSttConnect/main.swift`

- [ ] **Step 1: Read the current socket and trace path setup**

```bash
grep -n "socketPath\|/tmp/yappr\|trace\|YAPPR" \
  swift/yappr-stt-daemon/Sources/YapprSttDaemon/Daemon.swift \
  swift/yappr-stt-daemon/Sources/YapprSttConnect/main.swift \
  2>/dev/null | head -30
```

Note the exact variable names and line numbers.

- [ ] **Step 2: Update Daemon.swift — socket path and runtime dir**

Find where `socketPath` is defined (likely a `let` or `static let`). Replace the hardcoded `/tmp/yappr-stt.sock` with env-var resolution:

```swift
static var runtimeDir: String {
    let env = ProcessInfo.processInfo.environment
    if let d = env["YAPPR_RUNTIME_DIR"] { return d }
    return "/tmp/yappr-\(getuid())"
}

static var socketPath: String {
    let env = ProcessInfo.processInfo.environment
    if let s = env["YAPPR_SOCKET"] { return s }
    return "\(runtimeDir)/stt.sock"
}
```

After signal handler setup (before the main accept loop), add runtime dir creation:

```swift
let fm = FileManager.default
try? fm.createDirectory(
    atPath: Self.runtimeDir,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
)
```

Also add PID file write (and cleanup in defer):

```swift
let pidPath = ProcessInfo.processInfo.environment["YAPPR_DAEMON_PID"]
    ?? "\(Self.runtimeDir)/daemon.pid"
try? "\(ProcessInfo.processInfo.processIdentifier)".write(
    toFile: pidPath, atomically: true, encoding: .utf8
)
defer { try? FileManager.default.removeItem(atPath: pidPath) }
```

- [ ] **Step 3: Update Trace.swift — trace log path**

Find where the trace log path is set (something like `let tracePath = "/tmp/yappr-trace.log"` or similar). Replace with:

```swift
static var tracePath: String {
    let env = ProcessInfo.processInfo.environment
    if let t = env["YAPPR_TRACE_LOG"] { return t }
    let runtime = env["YAPPR_RUNTIME_DIR"] ?? "/tmp/yappr-\(getuid())"
    return "\(runtime)/trace.log"
}
```

- [ ] **Step 4: Update YapprSttConnect/main.swift — socket path**

Find where `socketPath` is set in `main.swift`. Replace with the same env-var pattern:

```swift
let env = ProcessInfo.processInfo.environment
let runtimeDir = env["YAPPR_RUNTIME_DIR"] ?? "/tmp/yappr-\(getuid())"
let socketPath = env["YAPPR_SOCKET"] ?? "\(runtimeDir)/stt.sock"
```

Also update trace path if referenced:

```swift
let tracePath = env["YAPPR_TRACE_LOG"] ?? "\(runtimeDir)/trace.log"
```

- [ ] **Step 5: Build to verify Swift compiles**

```bash
cd swift/yappr-stt-daemon
swift build -c release \
  --scratch-path "/Users/matteociccozzi/.local/share/yappr/build/yappr-stt-daemon" \
  2>&1 | tail -5
```

Expected: `Build complete!` (or just the binary copy lines with no errors).

- [ ] **Step 6: Re-apply ad-hoc codesign**

```bash
codesign --force --sign - \
  "/Users/matteociccozzi/.local/share/yappr/build/yappr-stt-daemon/release/YapprSttDaemon"
codesign --force --sign - \
  "/Users/matteociccozzi/.local/share/yappr/build/yappr-stt-daemon/release/YapprSttConnect"
echo "codesigned OK"
```

- [ ] **Step 7: Commit**

```bash
cd /Users/matteociccozzi/yappr
git add swift/yappr-stt-daemon/Sources/
git commit -m "feat: Swift daemon reads socket/trace/PID paths from YAPPR_* env vars

YapprSttDaemon and YapprSttConnect now resolve all runtime paths via
ProcessInfo.processInfo.environment with the same XDG-based fallbacks as
the bash path helper. Daemon also writes and cleans up a PID file."
```

---

### Task 8: Move Swift `.build/` out of source tree via `--scratch-path`

**Files:**
- Modify: `scripts/install.sh`
- Modify: `bin/yappr` (connect binary path)
- Modify: `.gitignore`

- [ ] **Step 1: Update install.sh Swift build step**

Find the `swift build` line for the daemon in `scripts/install.sh`. It currently looks like:

```bash
swift build -c release
```
or
```bash
(cd "$YAPPR_ROOT/swift/yappr-stt-daemon" && swift build -c release)
```

Add `--scratch-path`:

```bash
(cd "$YAPPR_ROOT/swift/yappr-stt-daemon" && \
  swift build -c release \
    --scratch-path "$YAPPR_DATA_HOME/build/yappr-stt-daemon")
```

Update the `DAEMON_BIN` and `CONNECT_BIN` vars (used for codesign and PATH references) to:

```bash
DAEMON_BIN="$YAPPR_DATA_HOME/build/yappr-stt-daemon/release/YapprSttDaemon"
CONNECT_BIN="$YAPPR_DATA_HOME/build/yappr-stt-daemon/release/YapprSttConnect"
```

- [ ] **Step 2: Update bin/yappr to use yappr_connect_binary()**

In `bin/yappr`, find the line that references `YapprSttConnect` with a hardcoded `.build` path. Replace with:

```bash
CONNECT_BIN="$(yappr_connect_binary)"
```

(The `yappr_connect_binary` function in `_yappr-paths.sh` returns `$YAPPR_BUILD_DIR/yappr-stt-daemon/release/YapprSttConnect`.)

- [ ] **Step 3: Remove .build/ from .gitignore since it's no longer in the tree**

```bash
grep -n "\.build" .gitignore
```

Find and remove the line `swift/yappr-stt-daemon/.build/` (or `**/.build/`). The build outputs no longer live in the repo.

Verify:
```bash
grep "\.build" .gitignore && echo "still present — remove it" || echo "removed OK"
```

- [ ] **Step 4: Verify syntax**

```bash
bash -n scripts/install.sh && echo "syntax OK"
bash -n bin/yappr && echo "syntax OK"
```

- [ ] **Step 5: Commit**

```bash
git add scripts/install.sh bin/yappr .gitignore
git commit -m "feat: move Swift .build/ out of source tree via --scratch-path

Swift daemon now builds to \$YAPPR_DATA_HOME/build/yappr-stt-daemon/
(\$HOME/.local/share/yappr/build/...). The repo's swift/ directory no
longer accumulates binary artifacts. Removes .build/ from .gitignore
since it's no longer in the source tree."
```

---

### Task 9: Seed user config dir from install script

**Files:**
- Modify: `scripts/install.sh`

- [ ] **Step 1: Find a good insertion point in install.sh**

Find the step that installs mlx-lm (`step "mlx-lm"` or similar). Insert after it:

```bash
# -----------------------------------------------------------------------------
# User config directory
# -----------------------------------------------------------------------------

step "User config directory ($YAPPR_CONFIG_HOME)"

mkdir -p "$YAPPR_CONFIG_HOME/configs" "$YAPPR_CONFIG_HOME/prompts"

if [[ ! -f "$YAPPR_CONFIG_HOME/configs/default.json" ]]; then
  cp "$YAPPR_ROOT/configs/default.json" "$YAPPR_CONFIG_HOME/configs/default.json"
  ok "seeded configs/default.json"
fi

if [[ ! -f "$YAPPR_CONFIG_HOME/prompts/cleanup.txt" ]]; then
  cp "$YAPPR_ROOT/prompts/cleanup.txt" "$YAPPR_CONFIG_HOME/prompts/cleanup.txt"
  ok "seeded prompts/cleanup.txt"
fi

if [[ ! -L "$YAPPR_CONFIG_HOME/configs/active.json" ]]; then
  ln -s default.json "$YAPPR_CONFIG_HOME/configs/active.json"
  ok "active config → default.json"
fi

ok "user config at $YAPPR_CONFIG_HOME"
```

- [ ] **Step 2: Also update YAPPR_STATE_HOME dirs creation**

Before the first step that writes logs or metrics, add:

```bash
# Create XDG state dirs
mkdir -p "$YAPPR_STATE_HOME/logs" "$YAPPR_STATE_HOME/metrics"
mkdir -p "$YAPPR_RUNTIME_DIR"
chmod 0700 "$YAPPR_RUNTIME_DIR"
```

- [ ] **Step 3: Verify syntax**

```bash
bash -n scripts/install.sh && echo "syntax OK"
```

- [ ] **Step 4: Commit**

```bash
git add scripts/install.sh
git commit -m "feat: install.sh seeds XDG user config dir and creates state dirs

First install now creates \$YAPPR_CONFIG_HOME/{configs,prompts} with
shipped defaults and an active.json symlink. State and runtime dirs are
created early so subsequent steps can log to them."
```

---

### Task 10: Create migration script for existing runtime data

**Files:**
- Create: `scripts/migrate-runtime-state.sh`
- Modify: `.gitignore`

- [ ] **Step 1: Write the migration script**

```bash
cat > scripts/migrate-runtime-state.sh << 'MIGRATE'
#!/usr/bin/env bash
# migrate-runtime-state.sh — one-time migration from repo-local runtime dirs
# to XDG dirs. Run once after upgrading to the Tier 2 branch.
# Safe to run multiple times (idempotent).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../bin/_yappr-paths.sh"

echo "=== yappr runtime state migration ==="
echo "FROM: $YAPPR_ROOT/{logs,metrics}"
echo "TO:   $YAPPR_STATE_HOME/{logs,metrics}"
echo ""

yappr_ensure_dirs

MOVED=0

# Migrate logs
if [[ -d "$YAPPR_ROOT/logs" ]]; then
  for f in "$YAPPR_ROOT/logs"/*.log; do
    [[ -f "$f" ]] || continue
    dest="$YAPPR_STATE_HOME/logs/$(basename "$f")"
    if [[ ! -f "$dest" ]]; then
      mv "$f" "$dest"
      echo "  moved logs/$(basename "$f")"
      MOVED=$((MOVED + 1))
    else
      echo "  skipped logs/$(basename "$f") (already in state dir)"
    fi
  done
fi

# Migrate metrics
if [[ -d "$YAPPR_ROOT/metrics" ]]; then
  for f in "$YAPPR_ROOT/metrics"/*.jsonl; do
    [[ -f "$f" ]] || continue
    dest="$YAPPR_STATE_HOME/metrics/$(basename "$f")"
    if [[ ! -f "$dest" ]]; then
      mv "$f" "$dest"
      echo "  moved metrics/$(basename "$f")"
      MOVED=$((MOVED + 1))
    else
      echo "  skipped metrics/$(basename "$f") (already in state dir)"
    fi
  done
fi

echo ""
if [[ $MOVED -gt 0 ]]; then
  echo "Moved $MOVED file(s). Old empty dirs (logs/, metrics/) can be deleted:"
  echo "  rmdir $YAPPR_ROOT/logs $YAPPR_ROOT/metrics 2>/dev/null || true"
else
  echo "Nothing to migrate."
fi
MIGRATE
chmod +x scripts/migrate-runtime-state.sh
```

- [ ] **Step 2: Update .gitignore — remove runtime state lines**

```bash
grep -n "^logs/\|^metrics/\|^recordings/\|metrics\.bak" .gitignore
```

Remove those lines. These dirs no longer live in the repo, so gitignoring them is misleading.

Verify:
```bash
grep -E "^logs/|^metrics/|^recordings/" .gitignore && echo "still present" || echo "removed OK"
```

- [ ] **Step 3: Test migration script syntax**

```bash
bash -n scripts/migrate-runtime-state.sh && echo "syntax OK"
```

- [ ] **Step 4: Run migration on this machine to move existing log/metric files**

```bash
bash scripts/migrate-runtime-state.sh
```

Expected: lists any files moved (or "Nothing to migrate" if already clean).

- [ ] **Step 5: Commit**

```bash
git add scripts/migrate-runtime-state.sh .gitignore
git commit -m "feat: add migration script and clean up gitignore runtime entries

scripts/migrate-runtime-state.sh moves existing logs/ and metrics/ from
the repo root to \$YAPPR_STATE_HOME. .gitignore entries for runtime dirs
removed since they no longer live in the source tree."
```

---

### Task 11: Create `scripts/check-no-runtime-writes.sh`

**Files:**
- Create: `scripts/check-no-runtime-writes.sh`

This script is used in CI (Tier 3) to prevent regressions.

- [ ] **Step 1: Write the script**

```bash
cat > scripts/check-no-runtime-writes.sh << 'CHECK'
#!/usr/bin/env bash
# check-no-runtime-writes.sh — fails if any script writes to $YAPPR_ROOT.
# Run in CI to catch regressions where scripts write logs/metrics/sockets
# back into the source tree.
set -euo pipefail
YAPPR_ROOT="${YAPPR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

FAIL=0
PATTERNS=(
  '\$YAPPR_ROOT/logs'
  '\$YAPPR_ROOT/metrics'
  '\$YAPPR_ROOT/recordings'
  'YAPPR_ROOT.*\.log'
  'YAPPR_ROOT.*\.jsonl'
  'YAPPR_ROOT.*\.sock'
  'YAPPR_ROOT.*\.pid'
  '/tmp/yappr-stt\.sock'
  '/tmp/yappr-trace\.log'
)

FILES=()
while IFS= read -r -d '' f; do
  FILES+=("$f")
done < <(find "$YAPPR_ROOT/bin" "$YAPPR_ROOT/scripts" "$YAPPR_ROOT/diagnostics" \
  -type f \( -name "*.sh" -o -name "*.bash" -o -name "*.py" -o -perm /111 \) \
  ! -name "_*" \
  -print0 2>/dev/null)

for f in "${FILES[@]}"; do
  [[ "$f" == *"check-no-runtime-writes"* ]] && continue
  [[ "$f" == *"migrate-runtime-state"* ]] && continue
  for pat in "${PATTERNS[@]}"; do
    if grep -qE "$pat" "$f" 2>/dev/null; then
      echo "FAIL: $f contains forbidden write pattern: $pat"
      FAIL=1
    fi
  done
done

if [[ $FAIL -eq 0 ]]; then
  echo "OK: no runtime writes into source tree found in bin/, scripts/, diagnostics/"
fi
exit $FAIL
CHECK
chmod +x scripts/check-no-runtime-writes.sh
```

- [ ] **Step 2: Run it and verify it passes**

```bash
bash scripts/check-no-runtime-writes.sh
```

Expected: `OK: no runtime writes into source tree found in bin/, scripts/, diagnostics/`

If any FAILs appear, fix those files before committing.

- [ ] **Step 3: Commit**

```bash
git add scripts/check-no-runtime-writes.sh
git commit -m "feat: add check-no-runtime-writes.sh for CI enforcement

Scans bin/, scripts/, diagnostics/ for patterns that write runtime
state back into the source tree. Used in Tier 3 CI workflow to prevent
regression. Passes clean against current codebase."
```

---

### Task 12: Final verification and PR

**Files:**
- No code changes

- [ ] **Step 1: Run the audit script**

```bash
bash scripts/check-no-runtime-writes.sh
```

Expected: `OK`

- [ ] **Step 2: Shellcheck all bash scripts touched in this tier**

```bash
shellcheck bin/_yappr-paths.sh bin/yappr bin/yappr-config \
  scripts/migrate-runtime-state.sh scripts/check-no-runtime-writes.sh \
  scripts/install.sh 2>&1
```

Fix any SC errors (SC2034 unused var warnings in the path helper are OK).

- [ ] **Step 3: Python syntax check**

```bash
python3 -m py_compile bin/_yappr_paths.py bin/yappr-stats && echo "all OK"
```

- [ ] **Step 4: End-to-end smoke test**

Start the daemon manually with the new binary location and verify the socket appears in the runtime dir:

```bash
source bin/_yappr-paths.sh
yappr_ensure_dirs
"$(yappr_daemon_binary)" &
DAEMON_PID=$!
sleep 2
ls "$YAPPR_RUNTIME_DIR/"
kill $DAEMON_PID 2>/dev/null || true
```

Expected: `stt.sock` and `daemon.pid` visible in `$YAPPR_RUNTIME_DIR`.

- [ ] **Step 5: Verify git status is clean after a session**

```bash
git status
```

Expected: no modified or untracked files (all runtime writes went to XDG dirs).

- [ ] **Step 6: Review all commits on this branch**

```bash
git log feat/tier-1-install-fixes..HEAD --oneline
```

Expected: commits covering Tasks 2–11.

- [ ] **Step 7: Push and open PR**

```bash
git push -u origin feat/tier-2-runtime-separation
```

PR title: `feat: Tier 2 — separate source from runtime data`
PR target: `feat/tier-1-install-fixes`

PR body:
- ✅ `bin/_yappr-paths.sh` — single source of truth for all YAPPR_* paths (bash)
- ✅ `bin/_yappr_paths.py` — same for Python scripts
- ✅ All bash/Python/Swift scripts route runtime paths through helpers
- ✅ Swift daemon reads YAPPR_SOCKET, YAPPR_RUNTIME_DIR, YAPPR_DAEMON_PID from env
- ✅ Swift .build/ moved out of source tree via --scratch-path
- ✅ install.sh seeds user config dir at $YAPPR_CONFIG_HOME
- ✅ Migration script for existing logs/metrics
- ✅ CI audit script to prevent regression

**Test plan:** After install, run a dictation session, then run `git status` — expect clean tree.
