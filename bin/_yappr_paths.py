"""
_yappr_paths.py — import this module from Python scripts.
Provides path resolution matching bin/_yappr-paths.sh exactly.
Every path is overridable via the corresponding YAPPR_* env var.
"""
import os
import stat
from pathlib import Path


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


def share() -> Path:
    """Asset root: share/yappr/ for Homebrew installs, repo root otherwise."""
    r = root()
    candidate = r / "share" / "yappr"
    if candidate.is_dir():
        return candidate
    return r


def config_file() -> Path:
    env = os.environ.get("YAPPR_CONFIG")
    if env:
        return Path(env)
    user = config_home() / "configs" / "active.json"
    if user.exists():
        return user
    return share() / "configs" / "active.json"


def build_dir() -> Path:
    return Path(os.environ.get("YAPPR_BUILD_DIR") or data_home() / "build")


def connect_binary() -> Path:
    beside = Path(__file__).resolve().parent / "YapprSttConnect"
    if beside.exists() and os.access(beside, os.X_OK):
        return beside
    return build_dir() / "yappr-stt-daemon" / "release" / "YapprSttConnect"


def daemon_binary() -> Path:
    beside = Path(__file__).resolve().parent / "YapprSttDaemon"
    if beside.exists() and os.access(beside, os.X_OK):
        return beside
    return build_dir() / "yappr-stt-daemon" / "release" / "YapprSttDaemon"


def ensure_dirs() -> None:
    """Create all runtime and state dirs yappr needs."""
    logs_dir().mkdir(parents=True, exist_ok=True)
    metrics_dir().mkdir(parents=True, exist_ok=True)
    rd = runtime_dir()
    rd.mkdir(parents=True, exist_ok=True)
    rd.chmod(stat.S_IRWXU)  # 0700
