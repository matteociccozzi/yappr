# yappr Open-Source Hardening Plan

Generated from live install audit + deep repo analysis. Goal: `git clone --recurse-submodules … && ./scripts/install.sh` works for anyone, the repo feels like a proper Unix CLI tool, and contributors can navigate and extend it.

---

## Cross-cutting decisions

All path env vars follow XDG conventions with macOS-compatible defaults:

| Logical | Env var | Default |
|---|---|---|
| Repo / source root | `YAPPR_ROOT` | self-detected via `dirname "${BASH_SOURCE[0]}"` |
| Config dir | `YAPPR_CONFIG_HOME` | `${XDG_CONFIG_HOME:-$HOME/.config}/yappr` |
| Data dir | `YAPPR_DATA_HOME` | `${XDG_DATA_HOME:-$HOME/.local/share}/yappr` |
| State dir | `YAPPR_STATE_HOME` | `${XDG_STATE_HOME:-$HOME/.local/state}/yappr` |
| Cache dir | `YAPPR_CACHE_HOME` | `${XDG_CACHE_HOME:-$HOME/.cache}/yappr` |
| Runtime dir | `YAPPR_RUNTIME_DIR` | `${XDG_RUNTIME_DIR:-/tmp/yappr-$(id -u)}` |
| Socket | `YAPPR_SOCKET` | `$YAPPR_RUNTIME_DIR/stt.sock` |
| Trace log | `YAPPR_TRACE_LOG` | `$YAPPR_RUNTIME_DIR/trace.log` |
| Daemon log | `YAPPR_DAEMON_LOG` | `$YAPPR_STATE_HOME/logs/daemon.log` |
| Daemon PID | `YAPPR_DAEMON_PID` | `$YAPPR_RUNTIME_DIR/daemon.pid` |

Single source of truth: `bin/_yappr-paths.sh` (sourced by bash scripts) and `bin/_yappr_paths.py` (imported by Python scripts). Swift daemon reads the same vars via `ProcessInfo.processInfo.environment`.

---

## Tier 1 — Fix the install (P0 unblockers)

> Goal: `git clone && ./scripts/install.sh` succeeds cold. No manual steps.

### 1.1 — Vendor FluidAudio as a git submodule `[S]`
**Problem:** `vendor/FluidAudio` doesn't exist in a fresh clone. Swift build fails with an opaque CoreML error.
**Files:**
- Create `.gitmodules`: `[submodule "vendor/FluidAudio"] path = vendor/FluidAudio  url = https://github.com/FluidInference/FluidAudio.git`
- `.gitignore`: remove `vendor/FluidAudio/` line (now tracked via submodule pointer)
- `scripts/install.sh`: add submodule step before the Xcode check:
  ```bash
  step "Submodules"
  if [[ ! -f "$YAPPR_ROOT/vendor/FluidAudio/Package.swift" ]]; then
    git -C "$YAPPR_ROOT" submodule update --init --recursive
  fi
  [[ -f "$YAPPR_ROOT/vendor/FluidAudio/Package.swift" ]] || fail "submodule init failed"
  ok "vendor/FluidAudio present"
  ```
- `README.md` + `docs/installation.md`: clone line becomes `git clone --recurse-submodules …`

---

### 1.2 — Fix hardcoded shebang in `bin/yappr-mlx-server` `[S]`
**Problem:** Shebang `#!/Users/mciccozzi/.local/…` breaks on every other machine.
**Files:**
- Rename `bin/yappr-mlx-server` → `bin/yappr-mlx-server.py` (Python core, shebang `#!/usr/bin/env python3`)
- Create new `bin/yappr-mlx-server` bash launcher:
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if command -v uv >/dev/null 2>&1; then
    PY="$(uv tool run --from mlx-lm which python3 2>/dev/null || true)"
  fi
  exec "${PY:-python3}" "$HERE/yappr-mlx-server.py" "$@"
  ```
- No install-time shebang rewrite needed — resolves correctly on any machine.

---

### 1.3 — Auto-populate Nemotron model cache during install `[M]`
**Problem:** Daemon fails on first launch with CoreML "model not found". `fluidaudiocli` not on PATH and not built.
**Depends on:** 1.1
**Files:**
- `scripts/install.sh`: add new step after Swift daemon build, before codesign:
  ```bash
  step "Populate Nemotron model cache (~/.cache/fluidaudio/)"
  CACHE_DIR="$HOME/.cache/fluidaudio/models/nemotron-streaming/560ms"
  if [[ -f "$CACHE_DIR/preprocessor.mlmodelc/coremldata.bin" ]]; then
    ok "models already cached"
  else
    info "Building fluidaudiocli and downloading Nemotron models (~200 MB)..."
    (cd "$YAPPR_ROOT/vendor/FluidAudio" \
      && swift build -c release --product fluidaudiocli \
                     --scratch-path "$YAPPR_DATA_HOME/build/fluidaudio")
    WARMUP="$(mktemp).wav"
    python3 -c "
  import wave, struct
  with wave.open('$WARMUP', 'w') as f:
      f.setnchannels(1); f.setsampwidth(2); f.setframerate(16000)
      f.writeframes(struct.pack('<'+'h'*16000, *([0]*16000)))
  "
    "$YAPPR_DATA_HOME/build/fluidaudio/release/fluidaudiocli" \
      nemotron-transcribe --input "$WARMUP" --chunk 560 >/dev/null
    rm -f "$WARMUP"
    [[ -f "$CACHE_DIR/preprocessor.mlmodelc/coremldata.bin" ]] \
      || fail "model cache still empty after warmup"
    ok "models cached at $CACHE_DIR"
  fi
  ```

---

### 1.4 — Fix `YAPPR_ROOT` hardcoding in all remaining scripts `[S]`
**Problem:** `bin/yappr` and `bin/yappr-config` already hotfixed. Two more scripts still broken.
**Files:**
- `diagnostics/yappr-probe-caching` line 13: `YAPPR_ROOT="${YAPPR_ROOT:-$HOME/toolkit/yappr}"` → `YAPPR_ROOT="${YAPPR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"`
- `bin/yappr-stats`: temporary fix until Tier 2 lands:
  ```python
  _self = Path(__file__).resolve()
  YAPPR_ROOT = Path(os.environ.get("YAPPR_ROOT") or _self.parent.parent)
  METRICS_DIR = Path(os.environ.get("YAPPR_METRICS_DIR") or YAPPR_ROOT / "metrics")
  ```

---

### 1.5 — Write `~/.hammerspoon/init.lua` from install script `[M]`
**Problem:** Manual copy from docs, hardcoded `~/toolkit/yappr` breaks if cloned elsewhere.
**Files:**
- Create `scripts/templates/hammerspoon-init.lua.tmpl`: copy of the Lua block in `docs/installation.md`, with `"/toolkit/yappr/bin/yappr"` replaced by `"@YAPPR_BIN@"` placeholder.
- `scripts/install.sh`: add step after Hammerspoon cask install:
  ```bash
  step "Hammerspoon config (~/.hammerspoon/init.lua)"
  if [[ -d "/Applications/Hammerspoon.app" ]]; then
    mkdir -p "$HOME/.hammerspoon"
    HS_FILE="$HOME/.hammerspoon/init.lua"
    if [[ -f "$HS_FILE" ]] && ! grep -q "@yappr-installed@" "$HS_FILE"; then
      warn "$HS_FILE exists. Backing up to $HS_FILE.bak.$(date +%s)"
      cp "$HS_FILE" "$HS_FILE.bak.$(date +%s)"
    fi
    sed "s|@YAPPR_BIN@|$YAPPR_ROOT/bin/yappr|g" \
      "$YAPPR_ROOT/scripts/templates/hammerspoon-init.lua.tmpl" \
      > "$HS_FILE"
    ok "wrote $HS_FILE"
    info "Reload Hammerspoon (menu bar → Reload Config)"
  fi
  ```

---

### 1.6 — Post-install permissions checklist `[S]`
**Problem:** Hotkey fires, pipeline runs, text never types. No error anywhere. Accessibility + Input Monitoring silently missing.
**Files:**
- `scripts/install.sh`: rewrite the closing summary block to print:
  ```
  ⚠️  Three permissions you must grant manually (macOS will not prompt until first use):

    1. Microphone → YapprSttDaemon
       System Settings → Privacy & Security → Microphone

    2. Accessibility → Hammerspoon
       System Settings → Privacy & Security → Accessibility

    3. Input Monitoring → Hammerspoon
       System Settings → Privacy & Security → Input Monitoring

  After granting, reload Hammerspoon (menu bar icon → Reload Config).
  Run `yappr doctor` to verify everything is wired up correctly.
  ```

---

### 1.7 — Verify Tier 1 on a clean clone path `[S]`
**Depends on:** 1.1–1.6
- Manual gate: clone into `/tmp/yappr-test` (not `~/yappr` or `~/toolkit/yappr`), run `./scripts/install.sh -y`, confirm hotkey works. No code changes; this is a sign-off step.

---

## Tier 2 — Separate source from runtime data

> Goal: source tree contains only code + shipped configs + docs. All writes go to XDG dirs. `git status` is clean after install and after daily use.

### 2.1 — Introduce path-resolution helpers `[M]`
**Depends on:** nothing (foundational)
**Create:**
- `bin/_yappr-paths.sh` — sourced by all bash scripts. Sets and exports all `YAPPR_*` env vars per the table above. Provides helper functions: `yappr_ensure_dirs` (creates state/logs, state/metrics, runtime dir with 0700), `yappr_log_path` (returns `$YAPPR_STATE_HOME/logs/yappr-<stamp>.log`), `yappr_metric_path` (returns `$YAPPR_STATE_HOME/metrics/<YYYY-MM>.jsonl`).
- `bin/_yappr_paths.py` — same constants, importable Python module. Provides `paths.runtime_dir()`, `paths.metrics_dir()`, `paths.logs_dir()`, `paths.trace_log()`, `paths.socket()`, `paths.daemon_log()`, `paths.config_dir()`.

---

### 2.2 — User config dir with ship-default fallback `[M]`
**Depends on:** 2.1
**Files:**
- `bin/yappr-config`: change `CONFIG_DIR` to search `$YAPPR_CONFIG_HOME/configs/` first, fall back to `$YAPPR_ROOT/configs/`. Active symlink lives in `$YAPPR_CONFIG_HOME/configs/active.json`. `yappr config use <NAME>` seeds user config dir from ship dir if not yet initialized.
- `bin/yappr` (line 114): `YAPPR_CONFIG="${YAPPR_CONFIG:-$YAPPR_CONFIG_HOME/configs/active.json}"`. Add fallback to `$YAPPR_ROOT/configs/active.json` if user dir not yet initialized.
- `bin/yappr` (prompt_file resolution): try `$YAPPR_CONFIG_HOME/$prompt_file` first, fall back to `$YAPPR_ROOT/$prompt_file`. Lets users override `prompts/cleanup.txt` without touching the repo.
- `diagnostics/yappr-probe-caching`: same prompt file resolution.
- `scripts/install.sh`: add seeding step after mlx-lm:
  ```bash
  step "User config directory"
  mkdir -p "$YAPPR_CONFIG_HOME/configs" "$YAPPR_CONFIG_HOME/prompts"
  [[ -f "$YAPPR_CONFIG_HOME/configs/default.json" ]] \
    || cp "$YAPPR_ROOT/configs/default.json" "$YAPPR_CONFIG_HOME/configs/default.json"
  [[ -f "$YAPPR_CONFIG_HOME/prompts/cleanup.txt" ]] \
    || cp "$YAPPR_ROOT/prompts/cleanup.txt" "$YAPPR_CONFIG_HOME/prompts/cleanup.txt"
  [[ -L "$YAPPR_CONFIG_HOME/configs/active.json" ]] \
    || ln -s default.json "$YAPPR_CONFIG_HOME/configs/active.json"
  ok "config: $YAPPR_CONFIG_HOME"
  ```

---

### 2.3 — Move metrics + logs out of the repo `[M]`
**Depends on:** 2.1
**Files:**
- `bin/yappr`: `LOGS_DIR="$YAPPR_STATE_HOME/logs"`, `METRIC_FILE="$(yappr_metric_path)"`.
- `bin/yappr-stats`: import `_yappr_paths.py`, `METRICS_DIR = paths.metrics_dir()`. Archive dir → `$YAPPR_STATE_HOME/metrics.bak.<ts>/`.
- `.gitignore`: remove `logs/`, `metrics/`, `metrics.bak.*/`, `recordings/` lines.
- Create `scripts/migrate-runtime-state.sh`: moves existing `$YAPPR_ROOT/metrics/*.jsonl` and `$YAPPR_ROOT/logs/*.log` to new locations, then `git rm -r` the now-empty dirs. Run once after this tier lands.

---

### 2.4 — Move socket + trace + daemon log + PID to `$YAPPR_RUNTIME_DIR` `[L]`
**Depends on:** 2.1
**Files:**
- `swift/yappr-stt-daemon/Sources/YapprSttDaemon/Daemon.swift`:
  ```swift
  static var socketPath: String {
      let env = ProcessInfo.processInfo.environment
      if let s = env["YAPPR_SOCKET"] { return s }
      let runtime = env["YAPPR_RUNTIME_DIR"] ?? "/tmp/yappr-\(getuid())"
      return "\(runtime)/stt.sock"
  }
  ```
  Create runtime dir before bind: `FileManager.default.createDirectory(atPath: runtimeDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])`.
- `swift/yappr-stt-daemon/Sources/YapprSttDaemon/Trace.swift`: same env-var pattern for trace log path.
- `swift/yappr-stt-daemon/Sources/YapprSttConnect/main.swift`: socket path and trace path both read from `ProcessInfo` with same fallback.
- `bin/yappr`: socket existence check reads `$YAPPR_SOCKET`, error message prints the actual resolved path.
- `bin/yappr-trace`: `LOG_PATH = paths.trace_log()`.
- `scripts/templates/hammerspoon-init.lua.tmpl`: add `@YAPPR_TRACE_LOG@` placeholder substituted by install.sh; Hammerspoon writes trace events to that path. Install.sh computes it as `$YAPPR_RUNTIME_DIR/trace.log` and substitutes both `@YAPPR_BIN@` and `@YAPPR_TRACE_LOG@`.

---

### 2.5 — Move Swift `.build/` out of the source tree `[S]`
**Depends on:** nothing
**Files:**
- `scripts/install.sh` daemon build step (line 241): add `--scratch-path "$YAPPR_DATA_HOME/build/yappr-stt-daemon"`.
- Update `DAEMON_BIN`/`CONNECT_BIN` vars in install.sh to point to new path.
- `bin/yappr`: replace `$YAPPR_ROOT/swift/…/.build/release/YapprSttConnect` with `$YAPPR_DATA_HOME/build/yappr-stt-daemon/release/YapprSttConnect`. Add `yappr_connect_binary()` helper in `_yappr-paths.sh`.
- `.gitignore`: remove `swift/yappr-stt-daemon/.build/` (builds outside tree now).

---

### 2.6 — Audit + verify no runtime writes remain in source tree `[S]`
**Depends on:** 2.2–2.5
- Create `scripts/check-no-runtime-writes.sh`: greps `bin/`, `scripts/`, `diagnostics/` for `>`, `>>`, `mkdir`, `tee` operations whose target contains `$YAPPR_ROOT`. Exits 1 if any found. Used in CI (Tier 3.10).
- Run it manually; fix any stragglers.

---

## Tier 3 — Polish + open-source readiness

> Goal: daemon supervision, doctor command, unified subcommand UX, CI.

### 3.1 — launchd plist for daemon auto-start `[M]`
**Depends on:** 2.4
**Create:**
- `scripts/templates/com.yappr.daemon.plist.tmpl`: `LaunchAgent` plist with `@DAEMON_BIN@`, `@YAPPR_RUNTIME_DIR@`, `@YAPPR_STATE_HOME@` placeholders. Key fields: `RunAtLoad=true`, `KeepAlive=true` (with `Crashed` condition), `StandardErrorPath=$YAPPR_STATE_HOME/logs/daemon.log`, `EnvironmentVariables` block for all `YAPPR_*` vars, `ProcessType=Interactive` (required for mic).
- `scripts/install.sh`: add step "Daemon auto-start at login (optional)". Renders plist to `~/Library/LaunchAgents/com.yappr.daemon.plist` and calls `launchctl bootstrap "gui/$(id -u)"`.

---

### 3.2 — `yappr` becomes a subcommand dispatcher `[M]`
**Depends on:** 2.1
**Files:**
- Rename current `bin/yappr` → `bin/yappr-dictate` (the real orchestrator, unchanged logic).
- Create new `bin/yappr` dispatcher:
  ```bash
  #!/usr/bin/env bash
  source "$(dirname "${BASH_SOURCE[0]}")/_yappr-paths.sh"
  case "${1:-dictate}" in
    dictate|"") exec "$YAPPR_ROOT/bin/yappr-dictate" "${@:2}" ;;
    daemon)     exec "$YAPPR_ROOT/bin/yappr-daemon"  "${@:2}" ;;
    config)     exec "$YAPPR_ROOT/bin/yappr-config"  "${@:2}" ;;
    stats)      exec "$YAPPR_ROOT/bin/yappr-stats"   "${@:2}" ;;
    trace)      exec "$YAPPR_ROOT/bin/yappr-trace"   "${@:2}" ;;
    doctor)     exec "$YAPPR_ROOT/bin/yappr-doctor"  "${@:2}" ;;
    server)     exec "$YAPPR_ROOT/bin/yappr-server"  "${@:2}" ;;
    help|-h|--help) exec "$YAPPR_ROOT/bin/yappr-help" ;;
    version|--version) echo "yappr $(cat "$YAPPR_ROOT/VERSION")"; exit 0 ;;
    *) echo "yappr: unknown subcommand '$1'" >&2; exit 2 ;;
  esac
  ```
- Hammerspoon spawns `yappr` with no args → dispatches to `yappr-dictate`. No `init.lua` changes needed.

---

### 3.3 — `yappr daemon` subcommand `[M]`
**Depends on:** 3.1, 3.2
**Create `bin/yappr-daemon`** with subcommands:
- `start`: check PID file + `kill -0`; if not running → `nohup "$DAEMON_BIN" >> "$YAPPR_DAEMON_LOG" 2>&1 & echo $! > "$YAPPR_DAEMON_PID"`; wait up to 5s for socket.
- `stop`: read PID, `kill -TERM`, wait 2s, escalate to `kill -KILL`, unlink socket and PID file.
- `restart`: stop + start.
- `status`: check PID file + `kill -0` + socket exists → print `running (pid=X, socket OK)` or `not running`.
- `logs`: `cat "$YAPPR_DAEMON_LOG"`.
- `tail`: `tail -F "$YAPPR_DAEMON_LOG"`.

---

### 3.4 — Daemon writes and cleans up a PID file `[S]`
**Depends on:** 2.4
**Files:**
- `swift/yappr-stt-daemon/Sources/YapprSttDaemon/Daemon.swift`: after signal handler setup:
  ```swift
  let pidPath = ProcessInfo.processInfo.environment["YAPPR_DAEMON_PID"]
      ?? "\(runtimeDir)/daemon.pid"
  try? "\(getpid())".write(toFile: pidPath, atomically: true, encoding: .utf8)
  // Cleanup on normal exit (not SIGKILL)
  defer { try? FileManager.default.removeItem(atPath: pidPath) }
  ```

---

### 3.5 — `yappr doctor` post-install verifier `[L]`
**Depends on:** 2.1–2.4, 3.2
**Create `bin/yappr-doctor`** (Python). Prints `[OK]`/`[WARN]`/`[FAIL]` per check, exits 1 on any FAIL:
1. macOS + Apple Silicon
2. Required commands on PATH: `jq`, `python3`
3. Required dirs exist + writable: `$YAPPR_CONFIG_HOME`, `$YAPPR_STATE_HOME/logs`, `$YAPPR_STATE_HOME/metrics`, `$YAPPR_RUNTIME_DIR`
4. Active config: valid JSON, `.llm.url` parseable, `.prompt_file` resolves
5. Daemon binary exists + is codesigned (`codesign -dv` exits 0)
6. Daemon process running (PID file + `kill -0`)
7. Socket exists + connectable (connect + immediate close)
8. LLM endpoint reachable (`GET ${llm_url}/../../health` or `/v1/models`, max 2s timeout)
9. Nemotron model cache populated (`~/.cache/fluidaudio/models/nemotron-streaming/560ms/preprocessor.mlmodelc/coremldata.bin`)
10. Hammerspoon installed + `init.lua` references correct path
11. `mlx_lm.server` on PATH (warn-only)
12. Print explicit hint for any FAIL pointing to the relevant System Settings pane

---

### 3.6 — Polish `yappr-stats` `[S]`
**Depends on:** 2.3
**Files:**
- `bin/yappr-stats`: import `_yappr_paths.py`; remove hardcoded `METRICS_DIR`. Update `cmd_clear` archive path. Remove stale "To call from anywhere" doc comment. Add `stt_total_held_ms` to default metric display. Ensure `--metrics-dir` CLI flag can override `paths.metrics_dir()` for power users.

---

### 3.7 — `yappr server` subcommand `[M]`
**Depends on:** 3.2, 1.2
**Create `bin/yappr-server`**: same shape as `yappr-daemon`. Subcommands: `start`, `stop`, `restart`, `status`, `logs`, `tail`. PID at `$YAPPR_RUNTIME_DIR/mlx-server.pid`. Log at `$YAPPR_STATE_HOME/logs/mlx-server.log`. `start` reads model/prompt/port from active config via `yappr-mlx-server --from-config`.

Add `--from-config` flag to `bin/yappr-mlx-server` launcher: reads `$YAPPR_CONFIG_HOME/configs/active.json` and forwards `--model`, `--system-prompt-file`, `--port` to Python core.

---

### 3.8 — `yappr help` `[S]`
**Depends on:** 3.2
**Create `bin/yappr-help`**: prints a `git`-style subcommand listing (daily commands, ops commands, env var overrides).

---

### 3.9 — Shell completions `[S]`
**Depends on:** 3.8
**Create:**
- `completions/yappr.bash`
- `completions/yappr.zsh`
- `completions/_yappr.fish`

`install.sh`: add step to copy into the appropriate shell completion dir.

---

### 3.10 — CI: GitHub Actions `[M]`
**Depends on:** 2.6
**Create:**
- `.github/workflows/ci.yml`: runs on push + PR on `macos-14` runner. Steps: submodule init, `swift build -c release --scratch-path /tmp/build`, ad-hoc codesign, `scripts/check-no-runtime-writes.sh`, `shellcheck bin/* scripts/*.sh diagnostics/*`, `ruff check bin/*.py`.
- `.github/workflows/release.yml`: on semver tag, builds daemon, bundles with scripts, creates GitHub Release with tarball.

---

### 3.11 — `VERSION` file `[S]`
**Depends on:** nothing
**Create `VERSION`**: single line `0.1.0`. Referenced by `yappr --version` and release workflow.

---

## Tier 4 — Documentation

> Goal: every doc reflects the new structure. New contributors can onboard without asking questions.

### 4.1 — Rewrite `README.md` Quick Install `[S]`
- Clone line → `git clone --recurse-submodules …`
- Add "Permissions you must grant" callout (Mic, Accessibility, Input Monitoring + exact Settings paths)
- Add `yappr doctor` callout as the verification step

### 4.2 — Rewrite `docs/installation.md` `[M]`
- Remove all `~/toolkit/yappr` references → `$YAPPR_ROOT`
- Hammerspoon: explain `install.sh` writes `init.lua` for you
- New section: "Where yappr stores data" — XDG table
- New section: "Running the daemon" — `yappr daemon start` (primary), launchd (default after install), manual (fallback)
- Remove old "run the binary directly" instructions

### 4.3 — Rewrite `docs/configuration.md` `[S]`
- Add all new `YAPPR_*` env vars to the env-var table
- Explain user config dir vs. shipped defaults and the search order
- `prompt_file` resolution: user dir first, ship dir fallback

### 4.4 — Update `docs/metrics.md` and `docs/diagnostics.md` `[S]`
- Metrics: `metrics/<YYYY-MM>.jsonl` → `$YAPPR_STATE_HOME/metrics/<YYYY-MM>.jsonl`
- Diagnostics: `/tmp/yappr-trace.log` → `$YAPPR_RUNTIME_DIR/trace.log`, add `yappr doctor` section

### 4.5 — Update `docs/architecture.md` `[S]`
- Socket label in pipeline diagram → `$YAPPR_RUNTIME_DIR/stt.sock`
- Daemon section: notes env vars consumed

### 4.6 — Update `docs/customization.md` `[S]`
- Prompt editing: "edit `$YAPPR_CONFIG_HOME/prompts/cleanup.txt`" (not the repo copy)
- Config swap: point to `yappr config use` with correct config dir

### 4.7 — New `CONTRIBUTING.md` `[M]`
- Dev setup: `git clone --recurse-submodules`, `./scripts/install.sh -y --skip-optional`
- Repo layout map: what each top-level dir is for
- Rule: "no runtime state lives in the repo" — explanation and enforcement via `check-no-runtime-writes.sh`
- How to add a subcommand: drop a `bin/yappr-foo`, add a case to `bin/yappr`
- How to add a config: copy defaults, edit, `yappr config use <name>`
- Running shellcheck + ruff locally
- Commit + PR conventions, release process

### 4.8 — New `docs/cli-reference.md` `[M]`
- One page, all subcommands + flags: `yappr dictate`, `yappr config`, `yappr stats`, `yappr trace`, `yappr daemon`, `yappr server`, `yappr doctor`
- Cross-links to detailed docs

### 4.9 — Update README docs table `[S]`
- Add `CONTRIBUTING.md` and `docs/cli-reference.md` rows

### 4.10 — Update `swift/yappr-stt-daemon/README.md` `[S]`
- Build path → `$YAPPR_DATA_HOME/build/…`
- Socket → `$YAPPR_RUNTIME_DIR/stt.sock`
- New section: env vars consumed by the daemon

### 4.11 — Retire `INSTALL_ISSUES.md` `[S]`
- Once Tier 1 is verified: delete or move to `docs/historical/` as a record. In-repo it confuses new readers.

---

## Sequencing constraints

```
1.1 → 1.3                (submodule before model cache warmup)
2.1 → 2.2, 2.3, 2.4, 2.5 (path helpers before everything in Tier 2)
2.4 → 3.1, 3.3, 3.4      (runtime dir before daemon supervision)
3.2 → 3.3, 3.5, 3.7, 3.8 (dispatcher before subcommands)
Tier 1 done → Tier 4.1–4.2
Tier 2 done → Tier 4.3–4.6
Tier 3 done → Tier 4.7–4.9
```

## Effort summary

| Tier | Tasks | S | M | L |
|---|---|---|---|---|
| 1 — Install fixes | 7 | 5 | 2 | 0 |
| 2 — Runtime separation | 6 | 2 | 3 | 1 |
| 3 — Polish + OSS readiness | 11 | 4 | 5 | 2 |
| 4 — Docs | 11 | 8 | 3 | 0 |
| **Total** | **35** | **19** | **13** | **3** |

Rough timeline: Tier 1 (1 day) → Tier 2 (2 days) → Tier 3 (3–4 days) → Tier 4 (1 day).
