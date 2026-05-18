# 🔬 Diagnostics & Troubleshooting

## Troubleshooting common issues

### Mic permission

**Symptom:** recordings come out 0 bytes (you'll see `❌ Recording is empty` in the CLI output).

**Fix:** macOS hasn't granted Microphone access. System Settings → Privacy & Security → Microphone:
- For the Hammerspoon path: enable **Hammerspoon**.
- For CLI mode: enable the terminal you ran `yappr` from (Terminal.app, iTerm2, Warp, etc.).

After granting, quit and relaunch the app whose permission you just changed.

### Hammerspoon hotkey doesn't fire

**Symptom:** Ctrl+Option+Y does nothing, no "🎙️ Recording…" toast.

**Fix:**
1. Hammerspoon menu bar icon → **Reload Config**.
2. Check the **Console** (menu bar icon → Console) for Lua errors.
3. Ensure System Settings → Privacy & Security → **Input Monitoring** has Hammerspoon checked.

### Keystrokes don't appear at the cursor

**Symptom:** Recording works, server logs show a cleanup, but no text appears in the focused app.

**Fix:** Accessibility permission. System Settings → Privacy & Security → Accessibility → Hammerspoon.

### Port conflict

**Symptom:** `Address already in use` when starting `yappr-mlx-server`.

Default port for `yappr-mlx-server` is 8081. Stock `mlx_lm.server` defaults to 8080 — the `v2-mlx-q4` config uses that. If you run both, give them different ports and configs.

### Prompt-hash mismatch in server logs

**Symptom:** Server stderr shows `[cache] system prompt changed (got X, had Y) — rebuilding`.

**Cause:** You edited `prompts/cleanup.txt` while the server was running.

**Fix:** Nothing to fix — this is **expected and self-healing**. The server detects the change and rebuilds the cache. The first request after the edit pays a ~150ms cold prefill; subsequent requests are warm again. If you'd rather avoid even that one-time hit, restart the server after editing.

### FluidAudio binary not found

**Symptom:** yappr exits with `FluidAudio binary not found or not executable at <path>`.

**Fix:** Step 4 of [`installation.md`](installation.md) wasn't completed. The binary must exist at `vendor/FluidAudio/.build/arm64-apple-macosx/release/fluidaudiocli`. Rebuild:

```bash
cd vendor/FluidAudio
swift build -c release
cd -
```

### TTFT is suspiciously high

**Symptom:** `yappr-stats` shows `llm_ttft_ms` consistently >300 ms when you expected ~100 ms.

**Diagnosis:** Run the probe to check whether the active backend is doing prefix caching.

```bash
yappr-config active                                         # which config is active?
diagnostics/yappr-probe-caching 10                          # measure TTFT pattern
curl -s http://127.0.0.1:8081/health | jq                   # if v3/default: check warm_requests counter
```

If `warm_requests` is climbing on every dictation, caching is working. If the active config points at stock `mlx_lm.server` (port 8080), there's no cross-request caching — switch to `default`:

```bash
yappr-config use default
```

### Model produces empty output / refuses to dictate

**Symptom:** `cleaned_chars` is 0 or the typed text is "I cannot do that" or similar.

**Cause:** Either the model thinks the input is addressed to it (jailbreak), or the cleanup prompt is broken.

**Fix:** Check `prompts/cleanup.txt`'s framing. The shipped prompt has explicit examples for "is this a question" → `Is this a question?` to ground the "you are a transcript cleaner, not a chatbot" behavior. If you edited the prompt and removed those examples, the model may regress. See [`docs/customization.md`](customization.md).

## The cache probe (dev tool)

`diagnostics/yappr-probe-caching` is the verification tool used during development to confirm prefix caching works. It's not part of the dictation runtime — just point it at any LLM endpoint to check whether that endpoint reuses KV state across requests.

```bash
diagnostics/yappr-probe-caching 10
```

### What it does

1. Loads the active config — uses its LLM URL, params, and system prompt file (so the test conditions match real cleanup calls).
2. Sends one warmup request (discarded — burns off Metal kernel compilation).
3. Fires N (default 10) measurement requests, all with the same system prompt and varied tiny user messages.
4. Prints per-call TTFT and a summary.

### Reading the output

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
```

### Interpreting

The script's "is caching working" heuristic expects **lazy** per-request caching (where call 1 is slow and 2-N are fast). With `yappr-mlx-server`'s **pre-startup** caching, *all* calls are warm (the system prompt was already in the cache before any request arrived). The probe will report "no caching" for our server even though it's working correctly.

The actual smoking guns:
1. **Cross-config comparison.** Run the probe on `default` (ours, port 8081), note ~104ms. Switch to `v2-mlx-q4` (stock, port 8080), note ~153ms. That's the win.
2. **Server `/health` stats.** For `yappr-mlx-server`: `cold_prefills: 1, warm_requests: N` means the cache was built once at startup and reused N times.

```bash
curl -s http://127.0.0.1:8081/health | jq '{cached_prefix_tokens, cold_prefills: .stats.cold_prefills, warm_requests: .stats.warm_requests}'
```

See [`docs/performance.md`](performance.md) for the methodology in more depth.

## Logs

- **Per-run logs**: `logs/<timestamp>.log` — one file per `yappr` invocation. Includes every stage transition and any error.
- **Metrics**: `metrics/<YYYY-MM>.jsonl` — one record per run.
- **Server stderr**: if you ran `yappr-mlx-server > /tmp/yappr-mlx-server.log 2>&1`, look there. Includes `[prefill]`, `[serve]`, and `[cache]` events.

In-memory only (not persisted across server restarts):
- `cold_prefills` / `warm_requests` counters — `curl /health` to read.
