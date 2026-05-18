# 🛠️ Installation

A step-by-step guide to getting yappr running on a fresh M-series Mac.

## Requirements

**Hardware:** macOS on Apple Silicon (M1/M2/M3/M4). Not tested on Intel.

**Dependencies:**

| Dependency               | Required? | Purpose                                                    |
|--------------------------|-----------|------------------------------------------------------------|
| Xcode command-line tools | ✅ yes    | To build FluidAudio                                        |
| Homebrew                 | ✅ yes    | Easiest way to install the rest                            |
| `ffmpeg`                 | ✅ yes    | Hammerspoon uses it to capture audio                       |
| `sox`                    | ✅ yes    | CLI mode uses it to capture audio                          |
| `jq`                     | ✅ yes    | yappr scripts parse JSON with it                           |
| Python 3.12+             | ✅ yes    | Runs `yappr-llm-call`, `yappr-mlx-server`, `yappr-stats`   |
| `mlx-lm`                 | ✅ yes    | The MLX LM runtime — install via `uv tool install mlx-lm`  |
| FluidAudio               | ✅ yes    | Swift CLI for Parakeet — build it yourself (see below)     |
| Hammerspoon              | ⚪ optional | Push-to-talk hotkey. Without it, use CLI mode instead.   |

**macOS permissions:** Microphone access (for whichever app captures audio), Accessibility + Input Monitoring (for Hammerspoon to send keystrokes and register the hotkey).

## 1. Clone

```bash
git clone https://github.com/matteociccozzi/yappr.git ~/toolkit/yappr
cd ~/toolkit/yappr
```

Everything below assumes `YAPPR_ROOT=$HOME/toolkit/yappr`. If you want it somewhere else, set `YAPPR_ROOT` in your shell rc and the scripts will pick it up.

## 2. Homebrew dependencies

```bash
brew install ffmpeg sox jq python@3.12 uv
brew install --cask hammerspoon  # optional, but the nice UX
```

## 3. Install `mlx-lm`

The recommended way is with [`uv`](https://github.com/astral-sh/uv) so it gets its own isolated environment:

```bash
uv tool install mlx-lm
```

This puts `mlx_lm.*` entry points on your PATH and gives `yappr-mlx-server` a Python interpreter it can `#!`-into. (`yappr-mlx-server`'s shebang currently points at `~/.local/share/uv/tools/mlx-lm/bin/python3` — if your `uv` install lives elsewhere, edit the first line of `bin/yappr-mlx-server` to match.)

## 4. Build FluidAudio

FluidAudio is a vendored dep but **not** committed (see `.gitignore`). Clone and build it yourself into `vendor/`:

```bash
git clone https://github.com/FluidInference/FluidAudio.git vendor/FluidAudio
cd vendor/FluidAudio
swift build -c release
cd -
```

This produces `vendor/FluidAudio/.build/arm64-apple-macosx/release/fluidaudiocli`, which is what `bin/yappr` looks for. First-time inference downloads the Parakeet v2 model weights to a cache dir; that's normal.

## 5. Put the yappr scripts on your PATH

```bash
# add to ~/.zshrc or ~/.bashrc
export PATH="$HOME/toolkit/yappr/bin:$PATH"
```

Now `yappr`, `yappr-config`, `yappr-stats`, and `yappr-mlx-server` are all callable.

## 6. Start the MLX server

In one terminal (or as a launchd service — your call):

```bash
yappr-mlx-server \
    --model              mlx-community/Qwen3-1.7B-4bit \
    --system-prompt-file ~/toolkit/yappr/prompts/cleanup.txt \
    --host 127.0.0.1 --port 8081
```

The first run downloads the model from Hugging Face (~1 GB). You should see `[load] done in Xs` followed by `[prefill] done in ~150ms`, then `[serve] http://127.0.0.1:8081 (cached prefix: ~339 tokens)`. Sanity check:

```bash
curl -s http://127.0.0.1:8081/health | jq
```

```json
{
  "status": "ok",
  "model": "mlx-community/Qwen3-1.7B-4bit",
  "cached_prefix_tokens": 339,
  "stats": { "cold_prefills": 1, "warm_requests": 0 }
}
```

## 7. Set up Hammerspoon (optional but recommended)

Hammerspoon's config lives at `~/.hammerspoon/init.lua`, **not** in this repo. Drop the snippet below into that file. It binds Ctrl+Option+Y to push-to-talk and pipes the streamed output of `yappr` straight into `hs.eventtap.keyStrokes`.

```lua
-- yappr: hold Ctrl+Option+Y to record, release to dictate cleaned text at cursor.
-- Each token from the LLM is typed at the cursor as it arrives — clipboard never touched.

local YAPPR_BIN    = os.getenv("HOME") .. "/toolkit/yappr/bin/yappr"
local FFMPEG_BIN   = "/opt/homebrew/bin/ffmpeg"
local AUDIO_DEVICE = ":1"   -- MacBook Pro Microphone. List with:
                            --   ffmpeg -f avfoundation -list_devices true -i ""

local recording, recordTask, audioPath = false, nil, nil

local function startRecording()
  audioPath = string.format("/tmp/yappr-%s.wav", os.date("%Y%m%d-%H%M%S"))
  hs.alert.closeAll()
  hs.alert.show("🎙️ Recording…", 9999)
  recordTask = hs.task.new(FFMPEG_BIN, function() end, {
    "-hide_banner", "-loglevel", "error", "-y",
    "-f", "avfoundation", "-i", AUDIO_DEVICE,
    "-ac", "1", "-ar", "16000",
    audioPath,
  })
  recordTask:start()
end

local function stopRecordingAndProcess()
  if recordTask then recordTask:terminate(); recordTask = nil end
  local capturedPath = audioPath; audioPath = nil

  hs.timer.doAfter(0.15, function()           -- let ffmpeg flush WAV header
    hs.alert.closeAll(); hs.alert.show("🧹 Cleaning…", 0.4)

    local streamCallback = function(_, stdOut, _)
      if stdOut and #stdOut > 0 then hs.eventtap.keyStrokes(stdOut) end
      return true
    end
    local finalCallback = function(rc, _, stdErr)
      hs.alert.closeAll()
      if rc ~= 0 then
        local msg = (stdErr and #stdErr > 0) and stdErr:sub(-200) or ("rc=" .. tostring(rc))
        hs.alert.show("❌ " .. msg:sub(1, 120), 3)
      end
    end
    hs.task.new("/bin/bash", finalCallback, streamCallback, {
      "-lc",
      string.format(
        "YAPPR_QUIET=1 YAPPR_AUDIO_FILE=%q PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin %s",
        capturedPath, YAPPR_BIN
      ),
    }):start()
  end)
end

hs.hotkey.bind({"ctrl", "alt"}, "y",
  function() if not recording then recording = true; startRecording() end end,
  function() if recording then recording = false; stopRecordingAndProcess() end end
)

hs.alert.show("yappr loaded — hold Ctrl+Option+Y to dictate", 2)
```

Reload Hammerspoon (menu bar icon → Reload Config). Grant **Accessibility** and **Input Monitoring** permissions when macOS asks. You should see the "yappr loaded" toast.

**Audio device index.** `AUDIO_DEVICE = ":1"` is the second AVFoundation input on most M-series MacBooks. Find yours with:

```bash
ffmpeg -f avfoundation -list_devices true -i ""
```

## 8. Smoke test

```bash
yappr-config list      # should show 'default' as active
curl -s http://127.0.0.1:8081/v1/models | jq   # server up?
YAPPR_RECORD_SECS=4 yappr   # 4-second mic capture from a terminal, no hotkey
```

If everything works, hold Ctrl+Option+Y in any text field, say "um so like testing yappr one two three", release.

## Common install issues

See [`docs/diagnostics.md`](diagnostics.md) for troubleshooting.
