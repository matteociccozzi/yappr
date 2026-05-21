# yappr CLI Reference

## yappr setup

```
yappr setup
```

One-time post-install setup. Downloads the Nemotron STT model (~200 MB), installs mlx-lm via uv, creates XDG config and state directories, and writes `~/.hammerspoon/init.lua`. Run once after `brew install yappr`.

---

## yappr dictate

```
yappr [dictate]
```

Record microphone audio, transcribe with Nemotron STT, clean with Qwen LLM, and type the result at the cursor. Called automatically by the Hammerspoon hotkey (hold **Ctrl+Option+Y**, release to finalize).

Requires: STT daemon running (`yappr daemon start`), MLX server running (`yappr server start`).

**Env vars:**
- `YAPPR_QUIET=1` — suppress intermediate log output (set by Hammerspoon)
- `YAPPR_COPY=1` — also copy cleaned text to the macOS clipboard

---

## yappr config

```
yappr config <list|use|show>
```

Manage configurations in `$YAPPR_CONFIG_HOME/configs/`.

| Subcommand | Description |
|---|---|
| `list` | List available configs in user config dir |
| `use <name>` | Switch active config to `<name>.json` |
| `show` | Print the active config JSON |

Configs live at `~/.config/yappr/configs/`. `install.sh` seeds this directory from the shipped defaults in `configs/`.

---

## yappr daemon

```
yappr daemon <start|stop|restart|status|logs|tail>
```

Manage the `YapprSttDaemon` process.

| Subcommand | Description |
|---|---|
| `start` | Launch daemon in background; wait for socket to appear |
| `stop` | Send SIGTERM; escalate to SIGKILL after 2s |
| `restart` | stop + start |
| `status` | Print running status with pid |
| `logs` | Print `$YAPPR_DAEMON_LOG` |
| `tail` | Follow `$YAPPR_DAEMON_LOG` |

**Paths:**
- Daemon binary: `/opt/homebrew/bin/YapprSttDaemon` (Homebrew) or `~/.local/share/yappr/build/yappr-stt-daemon/release/YapprSttDaemon` (source install)
- Socket: `$YAPPR_SOCKET` (default: `/tmp/yappr-<uid>/stt.sock`)
- PID: `$YAPPR_DAEMON_PID` (default: `/tmp/yappr-<uid>/daemon.pid`)
- Log: `$YAPPR_DAEMON_LOG` (default: `~/.local/state/yappr/logs/daemon.log`)

---

## yappr server

```
yappr server <start|stop|restart|status|logs|tail>
```

Manage the MLX inference server (`yappr-mlx-server` — Qwen3 4-bit).

| Subcommand | Description |
|---|---|
| `start` | Read model/port/prompt from active config; launch in background |
| `stop` | Send SIGTERM; escalate to SIGKILL |
| `restart` | stop + start |
| `status` | Print running or not running |
| `logs` | Print `$YAPPR_STATE_HOME/logs/mlx-server.log` |
| `tail` | Follow `$YAPPR_STATE_HOME/logs/mlx-server.log` |

Model, port, and prompt file are read from the active config JSON (`llm.model`, `llm.port`, `prompt_file`).

---

## yappr stats

```
yappr stats [--metrics-dir DIR] [--hist METRIC] [--trend METRIC] [--since WHEN] [--all]
```

View dictation metrics from `$YAPPR_STATE_HOME/metrics/`.

| Flag | Description |
|---|---|
| `-n N` | Last N runs (default: 20) |
| `--all` | All runs |
| `--since WHEN` | Runs since ISO ts, 'today', '2 hours ago', etc. |
| `--hist METRIC` | ASCII histogram for one metric |
| `--trend METRIC` | ASCII trend chart for one metric |
| `--compare ISO_TS` | Split before/after a timestamp |
| `--by-config` | Group by config_version |
| `--metrics-dir DIR` | Override metrics directory |
| `--clear` | Archive metrics to `$YAPPR_STATE_HOME/metrics.bak.<ts>/` |

---

## yappr trace

```
yappr trace
```

Print the timing trace from the last dictation session. Trace lives at `$YAPPR_TRACE_LOG` (default: `/tmp/yappr-<uid>/trace.log`).

---

## yappr doctor

```
yappr doctor
```

Run 11 post-install health checks. Exits 0 if all pass, 1 if any fail.

Checks: macOS Apple Silicon, required tools on PATH, XDG dirs, active config validity, daemon binary + codesign, daemon process + socket, LLM endpoint, Nemotron model cache, Hammerspoon, mlx_lm on PATH.

---

## yappr help

```
yappr help
yappr --help
yappr -h
```

Print help text.

- `yappr help` / `yappr --help` — full help: all subcommands, examples, env var overrides, and docs links.
- `yappr -h` — compact one-screen subcommand summary.

---

## yappr version

```
yappr version
yappr --version
```

Print the version string from `$YAPPR_ROOT/VERSION`.

---

## Global env var overrides

All paths are overridable. See [docs/configuration.md](configuration.md) for the full table.

| Variable | Default | What it affects |
|---|---|---|
| `YAPPR_ROOT` | auto-detected | Source tree root |
| `YAPPR_CONFIG` | `~/.config/yappr/configs/active.json` | Active config file |
| `YAPPR_RUNTIME_DIR` | `/tmp/yappr-$(id -u)` | Socket, PID, trace |
| `YAPPR_STATE_HOME` | `~/.local/state/yappr` | Logs, metrics |
| `YAPPR_SOCKET` | `$YAPPR_RUNTIME_DIR/stt.sock` | STT socket |
