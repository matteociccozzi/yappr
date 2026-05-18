# ⚡ Performance

## Headline number

| Setup                                          | TTFT (mean) | TTFT range  | Notes                                   |
|------------------------------------------------|-------------|-------------|-----------------------------------------|
| Stock `mlx_lm.server` (no cross-request cache) | ~153 ms     | 112–148 ms  | Re-prefills the system prompt every call |
| `yappr-mlx-server` (prefix-cached)             | ~104 ms     | 103–110 ms  | **~32% reduction**, much tighter variance |

Measured on an M2 Max with `mlx-community/Qwen3-1.7B-4bit`, a ~340-token system prompt, varied tiny user messages. Your numbers will differ — measure your own with `yappr-stats` and the probe (described below).

## How prefix caching works

Stock `mlx_lm.server` ([open issue #1178](https://github.com/ml-explore/mlx-lm/issues/1178)) doesn't reuse KV state across independent OpenAI-style API requests. With a ~340-token system prompt, every cleanup call was paying ~150ms to re-prefill the same prompt. `yappr-mlx-server` does this differently:

- **At startup**: tokenize the system prompt (N tokens), build a fresh `make_prompt_cache(model)`, run one forward pass with the system tokens, force evaluation with `mx.eval(...)`. The KV cache now holds N tokens of state. Remember `N` and `hash(system_prompt)`.
- **Per request**: hash the incoming system message.
  - If it matches the cached one: walk each cache layer and set `kvc.offset = N`. The tensor allocations stay; the model only reads up to `offset`, so whatever was generated last time is effectively gone.
  - If it doesn't match (prompt file changed without a server restart): rebuild from scratch — pays a one-time ~150ms cold prefill, then warm again.
- **Generation**: tokenize the full conversation, slice off the first N tokens (we already have them cached), and pass only the user-message suffix to `stream_generate(..., prompt_cache=master_cache)`. Only those suffix tokens need new prefill work.

A `threading.Lock` serializes requests against the shared mutable cache — this server is intentionally single-tenant. The `/health` endpoint exposes `cold_prefills` and `warm_requests` counters so you can sanity-check from outside.

## Verifying caching with the probe

`diagnostics/yappr-probe-caching` fires N requests at the active LLM endpoint with the same system prompt and varied tiny user messages, then prints TTFT per call. Two regimes to look for:

- **Stock server (no caching)**: all N calls show similar TTFT around ~150 ms. The probe's heuristic falsely reports "no caching" (it expects call 1 high, calls 2-N low — which works for *lazy* caching, not for *pre-startup* caching like ours).
- **`yappr-mlx-server` (pre-cached)**: all N calls show similar TTFT around ~104 ms. *Same flat pattern*, but at a lower baseline. The smoking gun is the cross-config delta + `/health` showing `cold_prefills: 1, warm_requests: N`.

To run yourself:

```bash
diagnostics/yappr-probe-caching 10
```

To A/B two backends, switch configs first:

```bash
yappr-config use v2-mlx-q4    # stock mlx_lm.server
diagnostics/yappr-probe-caching 10
yappr-config use default      # yappr-mlx-server (prefix-cached)
diagnostics/yappr-probe-caching 10
```

## How the win scales

50 ms TTFT savings on a 1.7B model with a 340-token prompt isn't transformative on its own — Qwen3-1.7B is already fast. But the cost we're saving is the **prefill of the system prompt**, which scales linearly with:

1. **System prompt size**. Bigger prompts (more examples, more custom vocab) = larger absolute saving. 1000 tokens cached saves roughly 150 ms instead of 50 ms.
2. **Model size**. Prefill cost grows roughly linearly with model parameters. The same 340-token prompt on a 7B model would save ~200 ms; on a 30B model, ~500 ms.

Extrapolated:

| Model        | Prompt size | Uncached TTFT (est.) | Cached TTFT (est.) | Savings |
|--------------|-------------|----------------------|--------------------|---------|
| 1.7B (today) | 340 tok     | ~153 ms              | ~104 ms            | ~32%    |
| 1.7B         | 1000 tok    | ~300 ms              | ~110 ms            | ~63%    |
| 7B           | 340 tok     | ~500 ms              | ~120 ms            | ~75%    |
| 7B           | 1000 tok    | ~1100 ms             | ~150 ms            | ~86%    |

So the architecture we built is mostly paying for itself at current scale, and pays compound dividends if you ever push to a richer prompt or bigger model.

## Other latency contributors

End-to-end latency isn't just TTFT. Real perceived latency per dictation:

```
Hammerspoon release → ffmpeg flush (~150 ms) →
                       STT (Parakeet, ~RTF 0.1–0.2 × audio_seconds) →
                       LLM TTFT (~100 ms) →
                       LLM gen (~5–15 tok/s, completion-tokens dependent) →
                       text streaming to cursor in parallel with gen
```

For a 4-second utterance producing ~20 cleanup tokens:
- ffmpeg flush: ~150 ms (could probably be tuned down)
- STT: ~400 ms (Parakeet on M2 Max)
- LLM TTFT: ~104 ms (this doc)
- LLM gen: ~250 ms (20 tokens at ~80 tok/s)

Total: ~900 ms from key release to last character at cursor, but **first character at cursor ~650 ms** because streaming overlaps gen with display. Subjectively snappy.

## What we haven't done (yet)

- **Speculative decoding**: another major gen-time speedup. Researched + deferred — there's an [open bug in mlx-lm with the Qwen3 family](https://github.com/ml-explore/mlx-lm/issues/846), and at this model size the verifier-to-draft ratio isn't favorable enough to justify the work. Revisit if we ever upgrade the cleanup model to 7B+ or the upstream bug clears.
- **Disk-persisted prompt cache**: `save_prompt_cache(...)` to `.safetensors`, load at startup. Would make server restarts instant. Easy add when motivated.
- **Streaming STT**. Parakeet would have to run as audio is captured rather than at file close. Would shave ~150 ms of "ffmpeg flush + STT all at once".
