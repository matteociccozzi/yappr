# 🎨 Customization

## The cleanup prompt

`prompts/cleanup.txt` is the system prompt the LLM sees on every call. Edit it freely. After saving:

- **Server side**: `yappr-mlx-server` detects the hash mismatch on the next request and rebuilds the cache automatically (~150 ms one-time cold prefill). No restart needed. The `[cache] system prompt changed (got X, had Y) — rebuilding` line appears in the server's stderr.
- **Metrics**: `prompt_hash` in the JSONL changes. So you can A/B prompt edits with `yappr-stats --compare <iso-ts-before-edit>`.

### What the prompt should do

The shipped prompt is tightly framed as a **transcript cleaner**, not a chatbot. Key properties:

- Removes disfluencies ("um", "uh", "like", "you know", repeated words).
- Fixes grammar and adds punctuation.
- **Rewrites questions and commands** — never answers them. A user dictating "what time is the meeting" should get back `What time is the meeting?`, not `The meeting is at 3pm.`.
- Preserves technical terms, file paths, code identifiers verbatim.
- Interprets voice commands inline (see [`docs/usage.md`](usage.md) or the README).

### Custom vocabulary

The prompt has a section for force-spelling brand names and project names that STT might mangle. The shipped example:

```
# Custom vocabulary
- "yappr" is the name of this tool. ALWAYS spell it as lowercase "yappr".
  Replace any STT artifact such as "yapper", "Yapper", or "yapr" with
  "yappr". Use lowercase "yappr" EVEN at the start of a sentence (it is a
  brand name like "iPhone" or "macOS" — sentence-start capitalization does
  not apply).
```

Add your own. Anything you say frequently that Parakeet gets wrong is a candidate — internal project names, oddly-spelled company names, jargon.

> **Note:** A future improvement is to push custom vocab into Parakeet itself via FluidAudio's `--custom-vocab` flag, which biases the STT decoder at the source instead of fixing things downstream. The cleanup prompt is a workaround until that lands.

## The hotkey

Change the Hammerspoon binding by editing `~/.hammerspoon/init.lua`:

```lua
hs.hotkey.bind({"ctrl", "alt"}, "y", ...)   -- the default
hs.hotkey.bind({"cmd", "shift"}, "d", ...)  -- example: Cmd+Shift+D
```

Anything `hs.hotkey.bind` accepts works. Avoid the macOS `fn` key — it's not a normal Cocoa modifier and requires `hs.eventtap` instead of `hs.hotkey`, which is fussier.

## The model

Point `configs/default.json`'s `llm.model_name` at any other MLX model on Hugging Face, restart the server with that model:

```bash
yappr-mlx-server \
    --model              mlx-community/Qwen3-4B-4bit \
    --system-prompt-file ~/toolkit/yappr/prompts/cleanup.txt \
    --host 127.0.0.1 --port 8081
```

Bigger model = better cleanup quality, slower TTFT. The prefix caching trick still works as long as it's a standard full-attention transformer.

Configs are the right place for this — make a new one rather than editing `default.json` if you want to A/B:

```bash
cp configs/default.json configs/v4-qwen-4b.json
# edit v4-qwen-4b.json to point at the bigger model
yappr-config use v4-qwen-4b
# dictate a few times, then:
yappr-stats --compare-configs default v4-qwen-4b
```

## STT options

By default `bin/yappr` calls FluidAudio with:

```
fluidaudiocli transcribe <audio> --model-version v2 --language en --output-json <json>
```

- `--model-version v2` is Parakeet v2 (English-only). Swap to `v3` for multilingual. Slower.
- `--language en` is a hint to Parakeet. Adjust if you switch model versions.

These are currently hardcoded in `bin/yappr` — pull request welcome to move them into the config schema.

## Audio device

`AUDIO_DEVICE = ":1"` in `init.lua` refers to AVFoundation device index 1 (typically the MacBook Pro Microphone). To use a different mic:

```bash
ffmpeg -f avfoundation -list_devices true -i ""
```

Lists all audio inputs by index. Pick the one that matches your mic, then update `AUDIO_DEVICE`.

In CLI mode (no Hammerspoon), the env var is `YAPPR_COREAUDIO_DEVICE`. Default is `"MacBook Pro Microphone"` by name. Override:

```bash
YAPPR_COREAUDIO_DEVICE="External Mic" yappr
```

## Recording duration in CLI mode

Default is 10 seconds:

```bash
YAPPR_RECORD_SECS=8 yappr   # 8-second capture
```
