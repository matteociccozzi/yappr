# 🛠️ Installation

A step-by-step guide to getting yappr running on a fresh M-series Mac.

## Requirements

**Hardware:** macOS on Apple Silicon (M1/M2/M3/M4). Nemotron 0.6B is the
streaming STT model the daemon loads in-process; it has not been tested on
Intel.

**Permissions you'll grant later (not automatable):**

- **Microphone (TCC)** for `YapprSttDaemon` — system dialog the first time
  the daemon starts.
- **Accessibility + Input Monitoring** for Hammerspoon (if you use the
  push-to-talk hotkey) — granted from System Settings when Hammerspoon asks.

Everything else is handled by the install script.

## Recommended: one-shot install

```bash
git clone https://github.com/matteociccozzi/yappr.git ~/toolkit/yappr
cd ~/toolkit/yappr
./scripts/install.sh
```

The script is idempotent — safe to re-run. It will prompt before each
optional step.

**Flags:**

| Flag                | What it does                                                |
|---------------------|-------------------------------------------------------------|
| `-y`, `--yes`       | Assume yes to all prompts (non-interactive)                 |
| `--skip-optional`   | Skip Hammerspoon and `mlx-lm` (CLI mode, external LLM only) |
| `-h`, `--help`      | Print the help summary                                      |

## What the script handles for you

- Sanity-check macOS + Apple Silicon.
- Verify Xcode command-line tools (triggers `xcode-select --install` if
  missing, then asks you to re-run).
- Verify Homebrew is installed.
- Install required Homebrew formulas: `jq`, `python@3.12`.
- *(Optional)* Install Hammerspoon (cask) for the push-to-talk hotkey.
- *(Optional)* Install `mlx-lm` via `uv` for on-device LLM cleanup.
- `swift build -c release` of the daemon — produces `YapprSttDaemon` and
  `YapprSttConnect`.
- Ad-hoc `codesign --sign -` on both binaries. This gives the daemon a
  stable code-signing identity so the TCC microphone grant survives
  rebuilds.
- Add `yappr/bin/` to your shell rc (`~/.zshrc`, `~/.bashrc`, or fish
  equivalent).

**What it does NOT do:**

- Grant the macOS Microphone permission to the daemon (system dialog on
  first launch).
- Grant Hammerspoon Accessibility + Input Monitoring permissions.
- Configure your LLM endpoint — defaults to local MLX on `127.0.0.1:8081`;
  edit `configs/active.json` yourself if pointing at a different
  OpenAI-compatible API.
- Start the daemon at login. Run it in a tmux/screen pane, or wire up your
  own launchd agent.

## Manual install

For when you want to know every step. This mirrors what the script does.

### 1. Clone

```bash
git clone https://github.com/matteociccozzi/yappr.git ~/toolkit/yappr
cd ~/toolkit/yappr
```

### 2. Xcode command-line tools

```bash
xcode-select -p || xcode-select --install
```

Required to build the Swift daemon. The installer pops a system dialog;
wait for it to finish before continuing.

### 3. Homebrew packages

```bash
brew install jq python@3.12
```

`jq` is used by the bash glue scripts (config + trace tooling). Python 3.12
runs `bin/yappr-llm-call`.

### 4. Hammerspoon (optional)

```bash
brew install --cask hammerspoon
```

Skip this if you only want CLI mode (running `yappr` directly from a
terminal). With it, you get a global push-to-talk hotkey.

### 5. `mlx-lm` for on-device LLM cleanup (optional)

```bash
brew install uv          # if not already present
uv tool install mlx-lm
```

Without `mlx-lm`, you must point `configs/active.json` at an external
OpenAI-compatible endpoint instead.

### 6. Build the Swift daemon

```bash
cd swift/yappr-stt-daemon
swift build -c release
```

Produces:

- `.build/release/YapprSttDaemon` — the long-running daemon that owns the
  mic and runs streaming Nemotron 0.6B in-process.
- `.build/release/YapprSttConnect` — the tiny socket client (~5 ms
  startup) that `bin/yappr` spawns on each press.

### 7. Ad-hoc codesign

```bash
codesign --force --sign - .build/release/YapprSttDaemon
codesign --force --sign - .build/release/YapprSttConnect
cd -
```

TCC keys microphone permission by code-signing identity. Without a stable
signature, every rebuild becomes a new "app" to macOS and you get re-prompted
for mic access. Ad-hoc signing fixes that.

### 8. Add `yappr/bin/` to your PATH

```bash
echo 'export PATH="$HOME/toolkit/yappr/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

(Or `~/.bashrc`, or the fish equivalent.)

## Post-install setup

### Microphone permission

Start the daemon for the first time:

```bash
~/toolkit/yappr/swift/yappr-stt-daemon/.build/release/YapprSttDaemon
```

macOS shows a Microphone permission dialog during the daemon's startup
warm-up (it briefly opens the mic to pay AVAudioEngine's first-`start()`
cost so your first dictation is fast). Grant it. The orange dot will
flash on for ~100 ms and then go dark — that's expected.

If you ever need to reset the grant:

```bash
tccutil reset Microphone
```

then restart the daemon.

### Hammerspoon push-to-talk

Hammerspoon's config lives at `~/.hammerspoon/init.lua` (not in this repo).
Drop this in:

```lua
-- yappr: hold Ctrl+Option+Y to dictate.
-- Press → spawn bin/yappr, which opens the yappr-stt-daemon socket. The daemon
-- owns the mic (AVAudioEngine) and starts capturing as soon as the socket is
-- connected. Release → SIGTERM to bin/yappr → forwarded to the YapprSttConnect
-- client → half-closes the socket → daemon stops the mic and returns the
-- transcript. bin/yappr then runs the cleanup LLM and streams cleaned tokens
-- to stdout, which we type at the cursor.

local YAPPR_BIN = os.getenv("HOME") .. "/toolkit/yappr/bin/yappr"

local recording = false  -- guard against keyDown autorepeat
local task = nil

-- Append one telemetry event to /tmp/yappr-trace.log. Mirrors the format used
-- by the Swift daemon and Swift client: "<unix_microseconds> hs <event>\n".
local function trace(event)
  local us = math.floor(hs.timer.secondsSinceEpoch() * 1e6)
  local f = io.open("/tmp/yappr-trace.log", "a")
  if f then
    f:write(string.format("%d hs %s\n", us, event))
    f:close()
  end
end

local function start()
  trace("hs_press")
  hs.alert.closeAll()
  hs.alert.show("🎙️ Recording…", 9999)

  local streamCallback = function(_taskHandle, stdOut, _stdErr)
    if stdOut and #stdOut > 0 then
      hs.eventtap.keyStrokes(stdOut)
    end
    return true
  end

  local finalCallback = function(exitCode, _stdOut, stdErr)
    hs.alert.closeAll()
    if exitCode ~= 0 then
      local msg = (stdErr and #stdErr > 0) and stdErr:sub(-200) or ("rc=" .. tostring(exitCode))
      print("[yappr] failed: " .. msg)
      hs.alert.show("❌ " .. msg:sub(1, 120), 3)
    end
  end

  task = hs.task.new(
    "/bin/bash",
    finalCallback,
    streamCallback,
    {
      "-c",
      "YAPPR_QUIET=1 PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin " .. YAPPR_BIN,
    }
  )
  trace("hs_task_start_call")
  task:start()
  trace("hs_task_start_return")
end

local function stop()
  trace("hs_release")
  if task then
    task:terminate()
    task = nil
  end
end

hs.hotkey.bind({"ctrl", "alt"}, "y",
  function()
    if not recording then recording = true; start() end
  end,
  function()
    if recording then recording = false; stop() end
  end
)

hs.alert.show("yappr loaded — hold Ctrl+Option+Y to dictate", 2)
```

Reload Hammerspoon (menu bar icon → Reload Config). The first time, macOS
will ask for **Accessibility** and **Input Monitoring** permissions —
grant both. You should see the "yappr loaded" toast.

### LLM endpoint

`bin/yappr-llm-call` is an OpenAI-compatible client. By default it points
at a local MLX server on `127.0.0.1:8081`. To run one:

```bash
yappr-mlx-server \
    --model              mlx-community/Qwen3-1.7B-4bit \
    --system-prompt-file ~/toolkit/yappr/prompts/cleanup.txt \
    --host 127.0.0.1 --port 8081
```

To use a different endpoint (Anthropic-compatible gateway, a remote
LLM, etc.), edit `configs/active.json`. See [`docs/configuration.md`](configuration.md).

## Verification

In one terminal, start the daemon and watch it boot:

```bash
~/toolkit/yappr/swift/yappr-stt-daemon/.build/release/YapprSttDaemon
```

You should see log lines for model load, mic engine prepare + warm-up, and
finally `listening on /tmp/yappr-stt.sock`.

In a second terminal:

```bash
yappr-trace --tail
```

Now press your hotkey (or run `yappr` directly with no hotkey). Expected
trace events, in order:

- `hs hs_press` — Hammerspoon registered the keyDown
- `hs hs_task_start_call` / `hs_task_start_return` — bash spawned
- `connect …` — `YapprSttConnect` opened the socket
- `daemon session_open` / `daemon first_audio` — mic capturing
- `hs hs_release` — keyUp
- `daemon session_close` — `audio_ms\ttranscript\n` written back
- LLM cleanup tokens stream into the foreground app

If you see all of those, you're done.

## Troubleshooting

**`socket not found at /tmp/yappr-stt.sock`** — the daemon isn't running.
Start `YapprSttDaemon` and confirm `ls /tmp/yappr-stt.sock` shows a socket.

**First dictation drops the leading audio** — check the trace; if there's
no `hs hs_press` event, Hammerspoon hasn't loaded the new `init.lua`.
Reload via the menu bar icon. If `hs_press` is present but `daemon
first_audio` lags hundreds of milliseconds behind `connect`, the daemon
may not have completed its warm-up — wait for it to finish booting before
the first press.

**Microphone permission denied** — open System Settings → Privacy &
Security → Microphone and confirm `YapprSttDaemon` is enabled. If it's
not listed at all, reset with `tccutil reset Microphone` and restart the
daemon to re-trigger the prompt.

**Audio captured but transcript is empty** — the daemon got the audio
(check the `audio_ms` value in `/tmp/yappr-trace.log`), but cleanup
returned nothing. Almost always means the LLM endpoint is unreachable.
Test with `curl -s $(jq -r .llm.url configs/active.json)/health`.

**Mic indicator stays on between dictations** — the daemon's session
state is wedged. Kill and restart `YapprSttDaemon`; the orange dot should
extinguish.

**Rebuilt the daemon and macOS re-prompts for mic access** — the ad-hoc
codesign step was skipped. Re-run `codesign --force --sign -
.build/release/YapprSttDaemon` and restart.

For deeper diagnostics see [`docs/diagnostics.md`](diagnostics.md).
