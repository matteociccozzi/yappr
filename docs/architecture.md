# 🏗️ Architecture

## Pipeline at a glance

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

## Components

### 🎙️ `bin/yappr` — bash orchestrator
The entry point. Hammerspoon invokes it via `YAPPR_AUDIO_FILE=...` after recording. Loads the active config, runs STT via FluidAudio, hands cleanup off to `yappr-llm-call`, captures the metric blob from its stderr, appends one line to `metrics/<YYYY-MM>.jsonl`. In quiet mode (Hammerspoon path), stdout is just the streamed cleaned text — nothing else.

See the docstring at the top of `bin/yappr` for the full spec.

### 🐍 `bin/yappr-llm-call` — streaming HTTP helper (Python)
Reads request JSON from stdin, POSTs with `stream:true`, parses SSE, records the wall-clock timestamp of the first content chunk as real TTFT. Streams text on stdout as it arrives. Emits the final timing + token usage JSON on stderr's last line. The whole reason this exists is that `curl --write-out time_starttransfer` with `stream:false` measures "when the *entire* response was delivered" — not TTFT.

### 🧠 `bin/yappr-mlx-server` — custom MLX inference server (Python)
A tiny ~320-line server built on the `mlx_lm` library with **explicit prefix caching** (the trick stock `mlx_lm.server` doesn't do for independent API calls). Prefills the system prompt KV cache at startup; on every request resets each layer's `cache.offset` back to the prefix boundary so only the user-message suffix needs new prefill work.

Exposes:
- `POST /v1/chat/completions` — OpenAI-compatible, supports SSE streaming
- `GET /v1/models` — includes `cached_prefix_tokens` and `cached_prefix_hash`
- `GET /health` — `status`, `model`, `cached_prefix_tokens`, `cold_prefills`, `warm_requests`

See [`docs/performance.md`](performance.md) for the why and how, [`docs/architecture.md#yappr-mlx-server-internals`](#yappr-mlx-server-internals) below for mechanics.

### ⚙️ `bin/yappr-config` — config switcher (bash)
Atomic symlink-based config switching. `list`, `active`, `use NAME`, `show [NAME]`, `diff A B`. See [`docs/configuration.md`](configuration.md).

### 📊 `bin/yappr-stats` — metrics summarizer (Python)
Reads `metrics/*.jsonl`. Default view is a summary of the last 20 runs with mean / p50 / p95 / max for each metric. Plus histograms, trends, A/B comparisons. See [`docs/metrics.md`](metrics.md).

## Internal dev tools (not part of the user-facing CLI)

These live outside `bin/` because they aren't part of the dictation runtime — they're verification tools used during development.

### 🔬 `diagnostics/yappr-probe-caching`
A/B cache probe. Hits the active LLM endpoint N times with the same system prompt and varied tiny user messages, reports per-call TTFT. Used during development to verify whether a backend is actually doing prefix caching. Documented in [`docs/diagnostics.md`](diagnostics.md) for anyone curious to repro the benchmarks.

## yappr-mlx-server internals

The cache reset trick that makes this fast:

```python
# startup (called once)
sys_tokens = tokenizer.apply_chat_template([{"role": "system", "content": SYS}],
                                            tokenize=True, add_generation_prompt=False)
master_cache = make_prompt_cache(model)
_ = model(mx.array(sys_tokens)[None], cache=master_cache)
mx.eval([c.state for c in master_cache])
N = len(sys_tokens)
sys_prompt_hash = sha256(SYS)[:12]

# every request
incoming_sys = request_body["messages"][0]["content"]
if sha256(incoming_sys)[:12] != sys_prompt_hash:
    # prompt file changed without server restart — rebuild from scratch
    rebuild(incoming_sys)

# reset offset; underlying KV tensors stay allocated but model only reads up to offset
for layer in master_cache:
    layer.offset = N

# only the user-portion needs new prefill work
full_tokens = tokenizer.apply_chat_template(request_body["messages"],
                                             tokenize=True, add_generation_prompt=True)
user_tokens = full_tokens[N:]

for chunk in stream_generate(model, tokenizer, user_tokens,
                              prompt_cache=master_cache, sampler=sampler):
    yield_sse(chunk)
```

A `threading.Lock` serializes requests against the shared mutable cache — this server is intentionally single-tenant.

**Limitations:**
- Works only for standard full-attention transformers that support `make_prompt_cache(model)` with offset-based truncation. SSM/Mamba/hybrid models would need a different cache primitive.
- The cache is RAM-only; server restart pays a fresh cold prefill. `save_prompt_cache(...)` to disk is on the wishlist.

## Streaming pipeline end to end

What makes text **appear at the cursor while the LLM is still generating**:

1. **`yappr-llm-call`** reads the LLM server's SSE stream line by line. Stamps a wall-clock timestamp on the first `choices[0].delta.content` chunk → that's the real TTFT. Each chunk is `sys.stdout.write(...); sys.stdout.flush()`'d immediately.
2. **`bin/yappr`** doesn't capture or buffer `yappr-llm-call`'s stdout — it lets it flow straight through to its own stdout.
3. **Hammerspoon's `hs.task` `streamCallback`** fires whenever the child process writes. Each chunk is passed to `hs.eventtap.keyStrokes(chunk)`, which synthesizes character-by-character key events at the cursor.

Total path: LLM server → SSE stream → `yappr-llm-call` (stdout) → `yappr` (stdout passthrough) → Hammerspoon (streamCallback) → cursor (synthesized keystrokes).

**The clipboard is never read, never written.**

## Why bash for the orchestrator?

The orchestrator's job is shell glue — invoke processes, manage env vars, pipe stdin/stdout, append to files. Bash is the right tool. The interesting per-protocol bits (SSE streaming, KV-cache tricks) live in the Python helpers where they belong.
