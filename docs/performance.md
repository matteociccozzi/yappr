# Performance

Two stages to budget for separately:

1. **STT path** — Hammerspoon key release → Swift daemon → AVAudioEngine → Nemotron 0.6B streaming → final transcript. Latency here is dominated by AVAudioEngine internal buffer aggregation, not the model.
2. **LLM cleanup** — verbatim transcript → `bin/yappr-mlx-server` (Qwen3-1.7B-4bit, MLX) → first cleaned token at cursor. Latency here is dominated by system-prompt prefill, which we eliminate via explicit prefix caching.

All numbers below were measured on an M-series Mac by the author. Reproduce yours with the commands shown.

## Reproducing

```bash
yappr trace --summary --last 10     # per-session phase breakdown
yappr stats --since "today"         # mean/p50/p95/max across runs
```

`yappr-trace` reads `$YAPPR_RUNTIME_DIR/trace.log` (default: `/tmp/yappr-<uid>/trace.log`) — events from Hammerspoon, the Swift connector, and the daemon. `yappr-stats` reads `$YAPPR_STATE_HOME/metrics/*.jsonl` (one record per completed dictation).

## STT path — where the time goes

Cold front-truncation = ms between Hammerspoon key press and the first audio sample the daemon actually receives from the tap. With the engine kept hot (the daemon does this), steady-state breakdown for one keypress:

| Phase                                                              | Typical | Notes                                                                 |
|--------------------------------------------------------------------|---------|-----------------------------------------------------------------------|
| Hammerspoon → bash → `bin/yappr` → `swift_main`                    | 80–160 ms | Highly machine-dependent; includes binary page-cache misses on cold   |
| `swift_main` → daemon `engine.start()` returns                     | 50–80 ms | Swift startup + Unix socket connect + daemon `Session.run` + start    |
| `engine.start()` → first tap callback                              | 85–105 ms | **AVAudioEngine internal aggregation; structural floor**              |
| **Total front-truncation**                                         | **~150–200 ms** | Down from ~880–1300 ms before recent fixes                 |

End-truncation (key release → end of audio actually transcribed): ~85–105 ms. AVAudioEngine flushes its internal buffer on `stop()` *without* delivering it through the tap, so anything still in flight is lost. We accept this as the cost of the tap-based design.

Post-EOF Nemotron finalize (`manager.finish()`): ~30–50 ms. The streaming model has already consumed audio in real time, so all that's left is flushing a partial chunk.

To watch this live for one session:

```bash
yappr-trace --last 1
```

Each `daemon_*` event shows the µs offset within the session.

## LLM cleanup — prefix caching beats stock `mlx_lm.server`

Stock `mlx_lm.server` ([open issue #1178](https://github.com/ml-explore/mlx-lm/issues/1178)) doesn't reuse KV state across independent OpenAI-style requests. Every cleanup call re-prefills the same ~340-token system prompt. `bin/yappr-mlx-server` does this differently:

- **At startup**: tokenize the system prompt (N tokens), build `make_prompt_cache(model)`, run one forward pass, `mx.eval(...)` to force materialization. Remember `N` and `hash(system_prompt)`.
- **Per request**: hash the incoming system message.
  - Match → walk each cache layer and set `kvc.offset = N`. Tensor allocations stay; the model only reads up to `offset`, so prior generation state is effectively gone.
  - Mismatch (prompt file edited without server restart) → rebuild from scratch, pay one cold prefill, warm again afterwards.
- **Generation**: tokenize the full conversation, slice off the first N tokens (cached), pass only the suffix to `stream_generate(..., prompt_cache=master_cache)`.

A `threading.Lock` serializes requests against the shared mutable cache — this server is single-tenant by design. `/health` exposes `cold_prefills` and `warm_requests` counters.

### Headline numbers

| Setup                                          | TTFT (mean) | TTFT range  | Notes                                       |
|------------------------------------------------|-------------|-------------|---------------------------------------------|
| Stock `mlx_lm.server` (no cross-request cache) | ~153 ms     | 112–148 ms  | Re-prefills the system prompt every call    |
| `bin/yappr-mlx-server` (prefix-cached)         | ~104 ms     | 103–110 ms  | **~32% reduction**, much tighter variance   |

Measured with `mlx-community/Qwen3-1.7B-4bit`, ~340-token system prompt, varied tiny user messages.

Today's steady-state cleanup latency (with cache hits, short utterances):
- LLM TTFT: typically 170–220 ms
- LLM total: 200–300 ms

The TTFT-vs-baseline gap here vs the table above reflects that real-world prompt tokens (transcript + recent context) are larger than the empty-user-message probe; the *delta* between cached and uncached is still ~32%.

### Verifying caching from outside

```bash
diagnostics/yappr-probe-caching 10
```

Two regimes to look for:

- **Stock server**: all N calls show similar TTFT around ~150 ms. The probe's "lazy caching" heuristic falsely reports "no caching" — it expects call 1 high, calls 2–N low. That works for lazy caching, not pre-startup caching like ours.
- **`yappr-mlx-server`**: all N calls show similar TTFT around ~104 ms. *Same flat pattern*, lower baseline. Cross-config delta + `/health` showing `cold_prefills: 1, warm_requests: N` is the proof.

To A/B two backends:

```bash
yappr config use v2-mlx-q4    # stock mlx_lm.server
diagnostics/yappr-probe-caching 10
yappr config use default      # yappr-mlx-server (prefix-cached)
diagnostics/yappr-probe-caching 10
```

### How the win scales

50 ms TTFT savings on a 1.7B model with a 340-token prompt isn't transformative on its own. But the cost we're saving is the **prefill of the system prompt**, which scales linearly with prompt size and roughly linearly with model parameters.

| Model        | Prompt size | Uncached TTFT (est.) | Cached TTFT (est.) | Savings |
|--------------|-------------|----------------------|--------------------|---------|
| 1.7B (today) | 340 tok     | ~153 ms              | ~104 ms            | ~32%    |
| 1.7B         | 1000 tok    | ~300 ms              | ~110 ms            | ~63%    |
| 7B           | 340 tok     | ~500 ms              | ~120 ms            | ~75%    |
| 7B           | 1000 tok    | ~1100 ms             | ~150 ms            | ~86%    |

The architecture mostly pays for itself at current scale and compounds if you ever push to a richer prompt or bigger model.

## End-to-end budget

For a typical short dictation, cache-warm:

```
key press   → first tap callback        : ~150–200 ms   (STT front-truncation)
audio       → streaming Nemotron        : real-time, ~RTF < 1 on M-series
key release → final transcript ready    : ~85–105 ms tap flush + ~30–50 ms finalize
final text  → LLM TTFT                  : ~170–220 ms
LLM gen     → last char at cursor       : ~50–150 ms depending on completion length
```

First character at cursor lands ~500–600 ms after key release for typical utterances. Streaming overlaps gen with display, so the perceived latency to "something starting to type" is lower than the total.

## What we can't optimize further without a rewrite

AVAudioEngine's internal buffer aggregation (`engine.start()` → first tap callback, ~85–105 ms) is a hard structural floor for the current design. AVAudioEngine schedules tap callbacks on its own thread at its own buffer cadence; we can't shrink that gap further by configuring `installTap`.

Eliminating it requires bypassing AVAudioEngine entirely and using a raw CoreAudio `AURenderCallback` against the input AudioUnit. That's roughly 150 LoC of refactor in `swift/yappr-stt-daemon/Sources/YapprSttDaemon/MicCapture.swift`, swaps the engine + tap for direct HAL render callbacks, and brings its own failure modes (sample-format negotiation, render-thread realtime constraints). Worth it if the ~100 ms floor becomes the dominant complaint; not worth it today.

## Deferred LLM-side work

- **Speculative decoding** — another gen-time speedup. Researched + deferred: [open mlx-lm bug with Qwen3](https://github.com/ml-explore/mlx-lm/issues/846), and at this model size the verifier-to-draft ratio isn't favorable. Revisit if we upgrade to 7B+ or the upstream bug clears.
- **Disk-persisted prompt cache** — `save_prompt_cache(...)` to `.safetensors`, load at startup. Would make server restarts instant. Easy add when motivated.
