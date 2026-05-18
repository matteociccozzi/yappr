# yappr

**Local, private, low-latency voice dictation for macOS.** Hold a hotkey, talk, release — cleaned-up text streams onto your screen at the cursor. Everything runs on-device on Apple Silicon: Parakeet for speech-to-text, a small Qwen3 served by a custom MLX inference server with explicit prefix caching for cleanup. No network. No clipboard. No cloud.

> Screen recording placeholder — drop a gif here once you have one.

## What it is

yappr is a thin glue layer over three pieces that already exist and one piece that didn't:

1. **Parakeet v2** (English-only) running through [FluidAudio](https://github.com/FluidInference/FluidAudio) — fast on-device ASR.
2. **Qwen3-1.7B-4bit** via MLX — a small language model that rewrites the verbatim transcript into clean prose (removes "um", fixes grammar, adds punctuation, leaves your voice alone).
3. **Hammerspoon** — turns a global hotkey into a push-to-talk recorder and types each LLM token at the cursor as it arrives, character by character, Wispr-Flow style.
4. **`yappr-mlx-server`** — a tiny inference server we built on top of the `mlx_lm` library because stock `mlx_lm.server` does not cache the system-prompt KV across independent requests. With a fixed cleanup prompt of ~340 tokens, that re-prefill was the bulk of our TTFT every call. With caching we measure roughly **~32% TTFT reduction** on Qwen3-1.7B-4bit (≈153ms → ≈104ms on an M2 Max) and much tighter variance. The win scales linearly with prompt size and model size.

## Why it exists

I love [Wispr Flow](https://wisprflow.ai/). I just wanted the same experience without a cloud round-trip, without sending audio off my machine, and with the freedom to swap models / prompts / hotkeys around. yappr is the local equivalent — same push-to-talk-then-type UX, but everything runs on the laptop.

## Features

- **Push-to-talk** via Hammerspoon (Ctrl+Option+Y by default).
- **Streaming all the way through** — Hammerspoon types tokens at the cursor as the LLM emits them. No "wait for completion → paste" stall.
- **Clipboard is never touched.** Text is synthesized as keystrokes.
- **Explicit prefix caching** on top of MLX — the system prompt KV is prefilled at server startup and reused on every request.
- **Versioned configs** — swap backends/models/prompts atomically via a single CLI.
- **Per-run metrics** — every invocation appends a JSON line with TTFT, total LLM time, STT time, tokens, audio seconds, config hash, prompt hash. `yappr-stats` does histograms, trends, and A/B comparisons.
- **Custom dictation prompt** designed for transcript cleanup, not chat — the model rewrites questions and commands, it never answers them.
- **Standalone CLI mode** — if you don't want Hammerspoon you can run `yappr` from a terminal; it'll record from the mic via `sox`.
- **Diagnostics included** — `yappr-probe-caching` is an A/B tool that verifies whether a given LLM endpoint is doing prefix caching.

## Architecture

```
                  ┌─────────────────────────────────────────────────────────────┐
                  │  Hammerspoon  (init.lua, lives in ~/.hammerspoon)           │
                  │  • hotkey down → start ffmpeg → /tmp/yappr-<ts>.wav         │
                  │  • hotkey up   → SIGTERM ffmpeg                             │
                  │  • spawn `yappr` with YAPPR_AUDIO_FILE=<wav>                │
                  │  • streamCallback → hs.eventtap.keyStrokes(chunk)           │
                  └─────────────────────────────────────────────────────────────┘
                                            │
                                            ▼
                  ┌─────────────────────────────────────────────────────────────┐
                  │  bin/yappr  (bash orchestrator)                             │
                  │                                                             │
                  │  audio.wav ──► FluidAudio (Parakeet v2 ASR) ──► raw text   │
                  │                                                  │          │
                  │                                                  ▼          │
                  │                                       bin/yappr-llm-call    │
                  │                                       (Python, streams SSE) │
                  │                                                  │          │
                  │                                                  ▼          │
                  │                                stdout: streamed cleaned text┼──► to Hammerspoon
                  │                                stderr: final metric JSON    │
                  │                                                             │
                  │  metric.jsonl ◄── append one line per run                   │
                  └─────────────────────────────────────────────────────────────┘
                                            │ HTTP /v1/chat/completions
                                            ▼
                  ┌─────────────────────────────────────────────────────────────┐
                  │  bin/yappr-mlx-server  (Python, port 8081)                  │
                  │                                                             │
                  │  startup: tokenize system prompt (N tokens)                 │
                  │           → one forward pass populates KV cache             │
                  │  request: hash incoming system msg                          │
                  │           → if same: reset each layer's cache.offset = N    │
                  │             prefill only the user-message suffix            │
                  │           → if different: rebuild from scratch (~150ms)     │
                  │           → stream_generate(...) → SSE chunks               │
                  │           → final chunk carries usage{prompt,completion,    │
                  │                                       cached_prompt_tokens} │
                  └─────────────────────────────────────────────────────────────┘
```

## Performance

These are real numbers from an M2 Max running Qwen3-1.7B-4bit with the cleanup prompt at ~340 tokens. Your numbers will differ — measure on your own machine with `yappr-stats` and `yappr-probe-caching`.

| Setup                                          | TTFT (mean) | Notes                                   |
|------------------------------------------------|-------------|-----------------------------------------|
| Stock `mlx_lm.server` (no cross-request cache) | ~153 ms     | Re-prefills the system prompt every call|
| `yappr-mlx-server` (prefix-cached)             | ~104 ms     | **~32% reduction**, tighter variance    |

The savings scale linearly with prompt size and model size — bigger prompt or bigger model means bigger absolute win. STT via Parakeet v2 + FluidAudio is roughly real-time-factor 0.1–0.2× on M-series silicon for short clips; the LLM cleanup is what dominates end-to-end latency.

## Requirements

**Hardware:** macOS on Apple Silicon (M1/M2/M3/M4). Not tested on Intel.

**Tools you need to install:**

| Dependency               | Required? | Purpose                                                |
|--------------------------|-----------|--------------------------------------------------------|
| Xcode command-line tools | yes       | To build FluidAudio                                    |
| Homebrew                 | yes       | Easiest way to install the rest                        |
| `ffmpeg`                 | yes       | Hammerspoon uses it to capture audio                   |
| `sox`                    | yes       | CLI mode uses it to capture audio                      |
| `jq`                     | yes       | yappr scripts parse JSON with it                       |
| Python 3.12+             | yes       | Runs `yappr-llm-call`, `yappr-mlx-server`, `yappr-stats` |
| `mlx-lm`                 | yes       | The MLX LM runtime — install via `uv tool install mlx-lm` |
| FluidAudio               | yes       | Swift CLI for Parakeet — build it yourself (see below) |
| Hammerspoon              | optional  | Push-to-talk hotkey. Without it, use CLI mode instead. |

**macOS permissions:** Microphone access (for whichever app captures audio), Accessibility + Input Monitoring (for Hammerspoon to send keystrokes and register the hotkey).

## Installation

### 1. Clone

```bash
git clone https://github.com/matteociccozzi/yappr.git ~/toolkit/yappr
cd ~/toolkit/yappr
```

Everything below assumes `YAPPR_ROOT=$HOME/toolkit/yappr`. If you want it somewhere else, set `YAPPR_ROOT` in your shell rc and the scripts will pick it up.

### 2. Homebrew dependencies

```bash
brew install ffmpeg sox jq python@3.12
brew install --cask hammerspoon  # optional, but the nice UX
```

### 3. Install `mlx-lm`

The recommended way is with [`uv`](https://github.com/astral-sh/uv) so it gets its own isolated environment:

```bash
brew install uv
uv tool install mlx-lm
```

This puts `mlx_lm.*` entry points on your PATH and gives `yappr-mlx-server` a Python interpreter it can `#!`-into. (`yappr-mlx-server`'s shebang currently points at `~/.local/share/uv/tools/mlx-lm/bin/python3` — if your `uv` install lives elsewhere, edit the first line of `bin/yappr-mlx-server` to match.)

### 4. Build FluidAudio

FluidAudio is a vendored dep but **not** committed (see `.gitignore`). Clone and build it yourself into `vendor/`:

```bash
git clone https://github.com/FluidInference/FluidAudio.git vendor/FluidAudio
cd vendor/FluidAudio
swift build -c release
cd -
```

This produces `vendor/FluidAudio/.build/arm64-apple-macosx/release/fluidaudiocli`, which is what `bin/yappr` looks for. First-time inference downloads the Parakeet v2 model weights to a cache dir; that's normal.

### 5. Put the yappr scripts on your PATH

```bash
# add to ~/.zshrc or ~/.bashrc
export PATH="$HOME/toolkit/yappr/bin:$PATH"
```

Now `yappr`, `yappr-config`, `yappr-stats`, and `yappr-mlx-server` are all callable.

### 6. Start the MLX server

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

### 7. Set up Hammerspoon (optional but recommended)

Hammerspoon's config lives at `~/.hammerspoon/init.lua`, **not** in this repo. Drop the snippet below into that file (replace anything already there or merge as needed). It binds Ctrl+Option+Y to push-to-talk and pipes the streamed output of `yappr` straight into `hs.eventtap.keyStrokes`.

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

### 8. Smoke test

```bash
yappr-config list      # should show 'default' as active
curl -s http://127.0.0.1:8081/v1/models | jq   # server up?
YAPPR_RECORD_SECS=4 yappr   # 4-second mic capture from a terminal, no hotkey
```

If everything works, hold Ctrl+Option+Y in any text field, say "um so like testing yappr one two three", release.

## Usage

### The hotkey flow

1. Position your cursor in any text field.
2. **Hold Ctrl+Option+Y.** A "🎙️ Recording…" toast appears.
3. Talk.
4. **Release the key.** A "🧹 Cleaning…" toast flashes. Cleaned text streams in at the cursor.

### Voice commands

These are baked into `prompts/cleanup.txt`. The model interprets them inline and removes the command words from the output:

| Say                                              | Effect                                                |
|--------------------------------------------------|-------------------------------------------------------|
| "scratch that" / "delete that" / "ignore that"   | Remove the previous sentence                          |
| "new paragraph"                                  | Insert a paragraph break                              |
| "new line"                                       | Insert a single line break                            |
| "make this a list" / "bullet list"               | Reformat preceding items as a markdown bullet list    |
| "all caps X"                                     | Uppercase X (e.g. "all caps qa" → "QA")               |
| "period" / "comma" / "question mark" / etc.      | Insert that punctuation when clearly a directive      |

Questions and commands in your speech are **rewritten, not answered** — the prompt is tightly framed as a transcript cleaner, not a chatbot.

### Direct CLI usage

```bash
# Record from mic for 8 seconds, print cleaned text, show per-stage timings on stderr
YAPPR_RECORD_SECS=8 yappr

# Run against an existing wav file (what Hammerspoon does)
YAPPR_AUDIO_FILE=/tmp/foo.wav YAPPR_QUIET=1 yappr

# Cleaned text → clipboard too
YAPPR_COPY=1 yappr
```

| Env var                  | Default                  | Purpose                                                      |
|--------------------------|--------------------------|--------------------------------------------------------------|
| `YAPPR_CONFIG`           | `configs/active.json`    | Active config path                                           |
| `YAPPR_AUDIO_FILE`       | (unset)                  | Use existing wav instead of recording                        |
| `YAPPR_RECORD_SECS`      | `10`                     | Fixed mic-recording duration in CLI mode                     |
| `YAPPR_COREAUDIO_DEVICE` | `MacBook Pro Microphone` | sox CoreAudio device name                                    |
| `YAPPR_QUIET`            | `0`                      | `1` = stdout is just streamed text, no report                |
| `YAPPR_COPY`             | `0`                      | `1` = also `pbcopy` the cleaned text                         |
| `YAPPR_DEBUG`            | `1`                      | Verbose per-run logs in `logs/<ts>.log`                      |

## Configs

Configs are JSON files in `configs/`. `configs/active.json` is an atomic symlink to whichever one is current. Switching is one command.

```bash
yappr-config list                # show all configs, mark the active one
yappr-config active              # print active name
yappr-config use v2-mlx-q4       # atomically switch (symlink swap)
yappr-config show                # pretty-print active config
yappr-config show v1-baseline    # pretty-print a specific one
yappr-config diff default v2-mlx-q4   # normalized diff
```

The three configs shipped:

| Name           | Backend            | Model                          | Notes                                          |
|----------------|--------------------|--------------------------------|------------------------------------------------|
| `default`      | `yappr-mlx-server` | mlx-community/Qwen3-1.7B-4bit  | Prefix-cached. The recommended config.         |
| `v1-baseline`  | `llama-server`     | Qwen/Qwen3-1.7B-GGUF:Q8_0      | The original setup, kept around for comparison.|
| `v2-mlx-q4`    | `mlx_lm.server`    | mlx-community/Qwen3-1.7B-4bit  | Stock MLX server; **no** prefix caching.       |

Each config has a `version`, `description`, `backend`, `llm.{url, model_name, max_tokens, temperature, extra_params}`, and `prompt_file`. The whole config + the prompt file are independently hashed and stored on every run, so you can later filter your metrics by either.

## Metrics

Every `yappr` run appends one line to `metrics/<YYYY-MM>.jsonl`:

```json
{"ts":"2026-05-17T19:14:22Z","llm_url":"http://127.0.0.1:8081/v1/chat/completions",
 "config_version":"default","config_hash":"a8f2c1d4e0b3","backend":"yappr-mlx-server",
 "model_name":"mlx-community/Qwen3-1.7B-4bit","prompt_hash":"7b3d9e2a01f8",
 "stt_ms":420,"llm_ttft_ms":104,"llm_total_ms":312,"prompt_tokens":363,
 "completion_tokens":14,"audio_seconds":4.2,"raw_chars":58,"cleaned_chars":51}
```

`yappr-stats` summarizes and slices.

```bash
yappr-stats                     # summary of last 20 runs
yappr-stats --all               # all runs
yappr-stats --since "1 hour ago"
yappr-stats --hist llm_ttft_ms  # ASCII histogram of one metric
yappr-stats --trend llm_ttft_ms # ASCII trend line of the last N runs
yappr-stats --by-config         # one summary block per config_version
yappr-stats --compare-configs default v2-mlx-q4   # side-by-side A/B
yappr-stats --compare 2026-05-17T18:00:00Z        # before/after a cutoff
yappr-stats --raw               # dump matching records as JSONL
yappr-stats --clear             # archive metrics/ → metrics.bak.<ts>/
```

Example default output:

```
20 runs (last: 2026-05-17T19:14:22Z)
  config: default  model: mlx-community/Qwen3-1.7B-4bit  backend: yappr-mlx-server

  stt_ms              mean 412     p50 405     p95 488     max 510
  llm_ttft_ms         mean 104     p50 102     p95 121     max 138
  llm_total_ms        mean 298     p50 285     p95 412     max 480
  prompt_tokens       mean 363     p50 363     p95 363     max 363
  completion_tokens   mean 18      p50 17      p95 28      max 34
  audio_seconds       mean 4.10    p50 4.20    p95 5.80    max 6.20
  raw_chars           mean 62      p50 58      p95 92      max 121
  cleaned_chars       mean 55      p50 51      p95 84      max 110
  tokens_per_sec      mean 71.20   p50 71.80   p95 78.40   max 82.10
  stt_rtf             mean 0.10    p50 0.10    p95 0.12    max 0.14
```

Two derived metrics are computed on the fly: `tokens_per_sec` (completion tokens / generation time after TTFT) and `stt_rtf` (STT wall-clock / audio seconds — lower is faster).

## How it works under the hood

### The prefix caching trick

Stock `mlx_lm.server` ([issue #1178](https://github.com/ml-explore/mlx-lm/issues/1178)) doesn't reuse KV state across independent OpenAI-style API requests. With a ~340-token system prompt, every cleanup call was paying ~150ms to re-prefill the same prompt. `yappr-mlx-server` does this differently:

- **At startup**: tokenize the system prompt (N tokens), build a fresh `make_prompt_cache(model)`, run one forward pass with the system tokens, force evaluation with `mx.eval(...)`. The KV cache now holds N tokens of state. Remember `N` and `hash(system_prompt)`.
- **Per request**: hash the incoming system message.
  - If it matches the cached one: walk each cache layer and set `kvc.offset = N`. The tensor allocations stay; the model only reads up to `offset`, so whatever was generated last time is effectively gone.
  - If it doesn't match (prompt file changed without a server restart): rebuild from scratch — pays a one-time ~150ms cold prefill, then warm again.
- **Generation**: tokenize the full conversation, slice off the first N tokens (we already have them cached), and pass only the user-message suffix to `stream_generate(..., prompt_cache=master_cache)`. Only those suffix tokens need new prefill work.

A `threading.Lock` serializes requests against the shared mutable cache — this server is intentionally single-tenant. The `/health` endpoint exposes `cold_prefills` and `warm_requests` counters so you can sanity-check it from outside.

This only works for **standard full-attention transformers** that support `make_prompt_cache(model)` with `offset`-based truncation. SSM/Mamba/hybrid models would need a different cache primitive.

### Streaming end to end

The whole point of streaming is that **the user sees text appear at the cursor as the LLM generates it**, not after a half-second pause. Two things make that work:

1. **`yappr-llm-call`** reads the LLM server's Server-Sent Events line by line. When the first `choices[0].delta.content` chunk arrives, it stamps a wall-clock timestamp (the real TTFT — `curl --write-out time_starttransfer` with `stream:false` does not measure this, it measures "time until the *entire* response was delivered"). Each content chunk is `sys.stdout.write(...); sys.stdout.flush()`'d immediately. The final timing and token-usage metric is dumped on **stderr** as one JSON line.
2. **Hammerspoon's `hs.task` `streamCallback`** fires whenever the child process writes to stdout. Each chunk is fed straight to `hs.eventtap.keyStrokes(chunk)`, which synthesizes character-by-character key events. The clipboard is never read, never written.

`bin/yappr` glues the two together: `yappr-llm-call`'s stdout is yappr's stdout, which is Hammerspoon's stdout chunk via the streamCallback. The metric blob on stderr becomes one line in the metrics JSONL.

## Customization

- **Cleanup prompt**: edit `prompts/cleanup.txt`. The active config records `prompt_hash` on every run, so you can A/B prompt edits with `yappr-stats --compare <iso-ts>`. **Restart `yappr-mlx-server` after editing** so it re-prefills the cache with the new prompt (or just send one request — the server will detect the hash mismatch and rebuild automatically, paying one cold prefill).
- **Custom vocabulary**: the prompt has a section for force-spelling brand names. The current example is the "yappr is always lowercase" rule. Add your own (project names, oddly-spelled company names, etc.).
- **Hotkey**: change `{"ctrl", "alt"}, "y"` in `init.lua` to anything else. Anything `hs.hotkey.bind` accepts.
- **Different model**: point `default.json`'s `llm.model_name` at any other MLX model on HF (e.g. `mlx-community/Qwen3-4B-4bit`), restart the server with `--model <new-id>`. Bigger model = better cleanup, slower TTFT.

## Diagnostics

`diagnostics/yappr-probe-caching` hits the active LLM endpoint N times with the same system prompt and varying tiny user messages, printing TTFT for each:

```bash
yappr-probe-caching 10
```

Output looks like:

```
yappr-probe-caching
  config:        default
  model:         mlx-community/Qwen3-1.7B-4bit
  url:           http://127.0.0.1:8081/v1/chat/completions
  system prompt: 3287 chars
  calls:         10 (after 1 warmup)
─────────────────────────────────────────────
Warming up (first request — pays cold-start cost) ...
  warmup:  ttft=152ms  total=312ms

  call   ttft_ms     total_ms    gen_ms
  ─────  ──────────  ──────────  ──────────
  1      104         268         164
  2      102         265         163
  ...
  10     108         272         164

Summary:
  call 1 TTFT (cold):           104ms
  calls 2-10 TTFT (potentially warm):
    min:                        99ms
    mean:                       104ms
    max:                        112ms

  ✓ PREFIX CACHING LIKELY WORKING.
```

Useful to verify any backend — point a config at it, switch with `yappr-config use`, run the probe.

## Troubleshooting

**Mic permission**: if recordings come out 0 bytes, macOS hasn't granted Microphone access to whatever is recording. For Hammerspoon: System Settings → Privacy & Security → Microphone → Hammerspoon. For CLI: same, but the terminal you launched `yappr` from.

**Port conflict**: `yappr-mlx-server` defaults to 8081. Stock `mlx_lm.server` defaults to 8080 — the `v2-mlx-q4` config uses that port too. If you run both, give them different ports and configs.

**Prompt-hash mismatch warning** in the server logs (`[cache] system prompt changed`): you edited `prompts/cleanup.txt` while the server was running. That's fine — the server detects the change and rebuilds. The first request after the edit pays a cold prefill (~150ms one-time hit).

**Hammerspoon hotkey doesn't fire**: Hammerspoon menu bar icon → Reload Config. Check the console (icon → Console) for errors. Make sure Input Monitoring is granted in System Settings.

**Keystrokes don't appear at the cursor**: Accessibility permission. Same place in System Settings.

**FluidAudio binary not found**: re-check step 4 of installation. The binary path `vendor/FluidAudio/.build/arm64-apple-macosx/release/fluidaudiocli` must exist and be executable.

**TTFT is suspiciously high**: run `yappr-probe-caching` against the active config. If it reports "NO CLEAR PREFIX CACHING", you're on a stock `mlx_lm.server` (or similar) — switch to `default` config (which uses `yappr-mlx-server`).

## Roadmap / known limitations

- **English only** (Parakeet v2). Multilingual would mean swapping in Parakeet v3 — easy to wire up in FluidAudio, slightly slower.
- **No speculative decoding yet.** We researched it; there's an [open bug in mlx-lm with the Qwen3 family](https://github.com/ml-explore/mlx-lm/issues/846), so we deferred. The hooks are there — drop in a draft model when the bug clears and TTFT should drop another notable chunk.
- **Single-tenant inference server.** One lock, one shared cache. Don't put `yappr-mlx-server` behind a load balancer.
- **Full-attention models only.** SSM/Mamba/hybrid models won't work with the current cache primitive.
- **Cache is RAM-only.** Server restart pays a fresh cold prefill. A future version could `save_prompt_cache(...)` to disk.
- **Fixed-duration recording in CLI mode.** sox's signal handling under CoreAudio is broken on macOS — push-to-talk and SIGINT both fail. Hammerspoon uses ffmpeg, which handles SIGTERM cleanly, so the hotkey path doesn't have this problem.
- **No tests.** This is a personal tool, not a polished product. Caveat emptor.

## Credits

- [Wispr Flow](https://wisprflow.ai/) — the UX I was trying to reproduce locally.
- [MLX](https://github.com/ml-explore/mlx) and [mlx-lm](https://github.com/ml-explore/mlx-lm) — the runtime that makes this fast on a laptop.
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — the Swift CLI wrapping Parakeet.
- [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt_ctc-1.1b) — the ASR model.
- [Qwen3](https://qwenlm.github.io/) — the small LLM doing the cleanup.
- [Hammerspoon](https://www.hammerspoon.org/) — the hotkey / scripting layer that makes all of this feel like a real app.

---

Made by [@matteociccozzi](https://github.com/matteociccozzi). PRs and issues welcome.
