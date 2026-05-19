# 🎨 Customization

## The cleanup prompt

`prompts/cleanup.txt` is the system prompt the LLM sees on every call. Edit it freely. After saving:

- **Server side**: `yappr-mlx-server` detects the hash mismatch on the next request and rebuilds the cache automatically (~150 ms one-time cold prefill). No restart needed. The `[cache] system prompt changed (got X, had Y) — rebuilding` line appears in the server's stderr.
- **Metrics**: `prompt_hash` in the JSONL changes. So you can A/B prompt edits with `yappr-stats --compare <iso-ts-before-edit>`.

### What the prompt should do

The shipped prompt is tightly framed as a **dictation formatter**, not a chatbot. Key properties:

- Preserves the speaker's words verbatim — no rewriting, paraphrasing, or "polishing".
- Only does five things: sentence-start capitalization + terminal punctuation, sparing internal punctuation, disfluency strip ("um"/"uh"/"like"/repeated words), spoken→written contraction normalization ("gonna" → "going to"), and inline voice-command directives.
- **Rewrites questions and commands** — never answers them. A user dictating "what time is the meeting" should get back `What time is the meeting?`, not `The meeting is at 3pm.`.
- Knows about Nemotron 0.6B streaming artifacts: corrects "pneumotron"/"nematron" mishearings only in clear technical context, and leaves last-word truncations as-is rather than guessing.
- Preserves technical terms, file paths, code identifiers verbatim.
- Interprets voice commands inline (full list in the [README](../README.md#voice-commands)).

### How request params are assembled

The cleanup client merges the active config's `llm.extra_params` into the chat-completions request body. For the default Qwen3-1.7B-4bit config that means `chat_template_kwargs: {enable_thinking: false}` is appended to disable Qwen3's `<think>` block. Anything OpenAI-compatible-but-vendor-specific (sampling knobs, template kwargs, tool config) goes there — see [`docs/configuration.md`](configuration.md) for the schema.

### Custom vocabulary

`prompts/cleanup.txt` has a `# Custom vocabulary` section for force-spelling brand and project names that STT mangles. The shipped example pins `yappr` to lowercase. Add your own entries beneath it — anything you say frequently that Nemotron gets wrong is a candidate: internal project names, oddly-spelled company names, jargon. Pattern:

```
- "<correct spelling>" is <one-line context>. Replace STT artifacts
  (<variant>, <variant>, ...) with "<correct spelling>".
```

> **Note:** Biasing the STT decoder at the source (vs. fixing things downstream in the LLM prompt) would be cleaner. Not wired up yet — current FluidAudio streaming Nemotron path doesn't expose a custom-vocab knob from the daemon side.

## The hotkey

Change the Hammerspoon binding by editing the `hs.hotkey.bind({"ctrl", "alt"}, "y", ...)` line in `~/.hammerspoon/init.lua`. Modifier list and key follow `hs.hotkey.bind` rules. Avoid the macOS `fn` key — it's not a normal Cocoa modifier and requires `hs.eventtap` instead of `hs.hotkey`, which is fussier. Full init.lua template lives in [`docs/installation.md`](installation.md#hammerspoon-push-to-talk).

## The STT model

The streaming STT engine is hard-coded in `swift/yappr-stt-daemon/Sources/YapprSttDaemon/Daemon.swift`:

```swift
static let chunkSize: NemotronChunkSize = .ms560
static let cacheSubdir = "560ms"
```

There is no runtime flag — switching engines is an edit-and-rebuild. The daemon's `Package.swift` depends on `vendor/FluidAudio` for the underlying Nemotron model wrappers, so any swap is limited to what FluidAudio exposes (other `NemotronChunkSize` values, or a different FluidAudio ASR manager).

To change it:

```bash
# 1. Edit Daemon.swift — update chunkSize and cacheSubdir.
# 2. Rebuild.
cd ~/toolkit/yappr/swift/yappr-stt-daemon
swift build -c release

# 3. Re-codesign (TCC keys mic permission to the signature).
codesign --force --sign - .build/release/YapprSttDaemon

# 4. Restart the daemon.
pkill -x YapprSttDaemon
./.build/release/YapprSttDaemon
```

The first run after a model change populates `~/.cache/fluidaudio/models/nemotron-streaming/<cacheSubdir>/`; subsequent starts are fast.

## The cleanup LLM

Point `configs/active.json`'s `llm.model_name` at any other MLX model on Hugging Face, and `llm.url` at whatever serves it. For a local on-device swap, restart `yappr-mlx-server` with the new model:

```bash
yappr-mlx-server \
    --model              mlx-community/Qwen3-4B-4bit \
    --system-prompt-file ~/toolkit/yappr/prompts/cleanup.txt \
    --host 127.0.0.1 --port 8081
```

Bigger model = better cleanup quality, slower TTFT. The prefix caching trick still works as long as it's a standard full-attention transformer.

Any OpenAI-compatible chat-completions endpoint works — point `llm.url` at a remote gateway, llama.cpp, vLLM, etc. Vendor-specific knobs go in `llm.extra_params`.

Configs are the right place for this — make a new one rather than editing `default.json` if you want to A/B:

```bash
cp configs/default.json configs/v4-qwen-4b.json
# edit v4-qwen-4b.json to point at the bigger model
yappr-config use v4-qwen-4b
# dictate a few times, then:
yappr-stats --compare-configs default v4-qwen-4b
```
