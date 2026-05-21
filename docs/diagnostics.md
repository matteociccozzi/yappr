# Diagnostics & Troubleshooting

Three observability surfaces, in order of usefulness when something feels off:

1. **`bin/yappr-trace`** — end-to-end timeline of a dictation (Hammerspoon → socket client → daemon). Best for latency questions.
2. **`$YAPPR_STATE_HOME/logs/daemon.log`** — what the long-running Swift daemon is doing. Best for "why did it fail to start the mic".
3. **`$YAPPR_STATE_HOME/logs/<timestamp>.log`** — one file per `yappr` invocation. Best for cleanup / LLM-side issues.

Plus `$YAPPR_STATE_HOME/metrics/YYYY-MM.jsonl` for cross-run analysis (see `yappr stats`).

---

## The trace system

A push-to-talk session emits events from three processes into a single append-only file:

```
$YAPPR_RUNTIME_DIR/trace.log
```
(default: `/tmp/yappr-<uid>/trace.log`)

Format is one event per line: `<unix_microseconds> <source> <event> [k=v k=v ...]`. Writes are atomic per-syscall, so concurrent writers from Hammerspoon Lua, `YapprSttConnect`, and the daemon interleave safely.

View it with `bin/yappr-trace`. Events are grouped into five phases:

```
hammerspoon → spawn → daemon-setup → capture → finalize
```

### Modes

```bash
yappr-trace                  # last session as a phased timeline (default)
yappr-trace --last 3         # last N sessions
yappr-trace --all-sessions   # every session in the log
yappr-trace --summary        # one tab-separated row per session
yappr-trace --tail           # follow the file (like tail -F)
yappr-trace --raw            # dump rows untouched
yappr-trace --clear          # truncate (prompts; -y to skip)
```

Color is on by default on a TTY; auto-off when piped, when `NO_COLOR` is set, or with `--no-color`. Latency bands: `<50 ms` dim, `50–200` yellow, `≥200` red+bold.

### Timeline mode

```
=== session 4 of 12 — 2026-05-18 09:42:11 (18 events) ===
event                            source     +ms       Δms   details
--------------------------------------------------------------------------------
--- hammerspoon ---
hs_press                         hs           0.00      0.00
hs_release                       hs        1284.50      0.00
--- spawn ---
swift_main                       swift       12.40     12.40
--- daemon-setup ---
daemon_accept                    daemon      14.10      1.70
daemon_engine_start_call         daemon      14.30      0.10
daemon_engine_start_return       daemon      26.80     12.50
--- capture ---
daemon_first_tap                 daemon      72.40     45.60   frames=512
daemon_eof_received              daemon    1290.10    ...
--- finalize ---
daemon_engine_stop_returned      daemon    1295.20      5.10
daemon_finish_return             daemon    1340.80     45.60   len=43
daemon_write_done                daemon    1341.30      0.50   audio_ms=1217
```

`+ms` is offset from `hs_press`; `Δms` is delta from the previous event.

### Summary mode

```
#  when                  events  front_ms  end_ms  held_ms  audio_ms  len
1  2026-05-18 09:41:50   17      28.4      8.2     1102.0   1078       38
2  2026-05-18 09:42:11   18      26.8      6.3     1284.5   1217       43
```

- `front_ms` — gap between `hs_press` (or `swift_main` if absent) and `daemon_engine_start_return`. Anything pushing this above ~50 ms is interesting; above 200 ms is upstream of mic-open and worth investigating.
- `end_ms` — engine-window minus actual captured audio; tail drift on hotkey release.
- `held_ms` — how long the user held the hotkey.
- `audio_ms` — sample count / 16 kHz.
- `len` — transcript char count.

### Useful event names

| event | source | meaning |
|---|---|---|
| `hs_press`, `hs_release` | hs | hotkey edges from Hammerspoon |
| `swift_main` | swift | `YapprSttConnect` reached `main` |
| `daemon_accept` | daemon | socket accept |
| `daemon_engine_start_call` / `_return` | daemon | AVAudioEngine.start() bracket |
| `daemon_first_tap` | daemon | first audio buffer arrived from the HAL |
| `daemon_eof_received` | daemon | client half-closed (= hotkey release) |
| `daemon_engine_stop_returned` | daemon | mic indicator off |
| `daemon_finish_return` | daemon | STT finalize done, `len=N` chars |
| `daemon_write_done` | daemon | transcript written to socket, `audio_ms=N` |

---

## Daemon logs

The Swift daemon writes to stderr; the launchd unit (or however you run it) typically redirects to `$YAPPR_STATE_HOME/logs/daemon.log`. Lines worth grepping:

- `models loaded` — STT model weights mmap'd.
- `encoder warmed` — first encoder pass run, kernels compiled.
- `mic prepared` — tap installed, converter built; no HAL stream open yet.
- `mic warmed` — brief `start()`/`stop()` to pay first-`start()` cost.
- `listening on $YAPPR_RUNTIME_DIR/stt.sock` — ready for clients.
- `session telemetry: tap_fires=… tap_frames_native=… ingest_calls=… converted_samples_16k=…` — per-session capture-side counters.
- `session done: audio_ms=… finalize=…ms total=…ms` — overall timing.
- `input format changed: …→… — rebuilding tap + converter` — device format switched (e.g. AirPods connected mid-life); daemon handled it.
- `engine.start() got -10868; … reinstalling tap and retrying` — auto-recovery from `kAudioUnitErr_FormatNotSupported`.

---

## Per-run logs

`$YAPPR_STATE_HOME/logs/<timestamp>.log` — one file per `yappr` invocation, includes every stage transition, the LLM request, and stderr from `yappr-llm-call`. Path is printed to stderr at the end of each (non-quiet) run.

---

## Metrics

`$YAPPR_STATE_HOME/metrics/<YYYY-MM>.jsonl` — one JSON record per run. Keys:

- `audio_seconds`, `stt_ms`, `stt_total_held_ms`
- `llm_ttft_ms`, `llm_total_ms`, `prompt_tokens`, `completion_tokens`
- `raw_chars`, `cleaned_chars`
- `config_version`, `config_hash`, `prompt_hash`, `backend`, `model_name`, `llm_url`

The prompt and config hashes are there so you can A/B by filtering on them in `yappr stats`.

---

## Troubleshooting

### Socket not found

**Symptom:** `yappr` exits with `socket not found at $YAPPR_RUNTIME_DIR/stt.sock`.

**Cause:** The daemon isn't running. Start it (`yappr daemon start` or run it directly). Verify with `lsof $YAPPR_RUNTIME_DIR/stt.sock` or by tailing `$YAPPR_STATE_HOME/logs/daemon.log` for `listening on`.

### `engine.start()` returns -10868

**Symptom:** Daemon log shows `engine.start() got -10868` after plugging in / switching the input device (AirPods, USB mic).

**Cause:** The device's native input format changed since the tap was installed. The daemon auto-retries once: refreshes the format, reinstalls the tap, rebuilds the converter, and starts again. If you see this once per device-switch it's fine. If it persists across multiple sessions for the same device, restart the daemon.

### Microphone permission denied

**Symptom:** No `daemon_first_tap` events; daemon log shows zero tap fires; or macOS prompted you and you clicked Don't Allow.

**Fix:** Reset and re-grant. The TCC entry is attached to the binary that asked, which is the daemon itself.

```bash
tccutil reset Microphone
# Then restart the daemon — macOS will re-prompt on first start().
```

Privacy & Security → Microphone should list the daemon binary after that.

### Hammerspoon hotkey doesn't fire

**Symptom:** Pressing Ctrl+Option+Y does nothing. No `hs_press` row in `yappr-trace --tail`.

**Fix:**
1. Hammerspoon menu bar icon → **Reload Config**, then **Console** to check for Lua errors.
2. Privacy & Security → **Input Monitoring** must have Hammerspoon enabled.
3. Privacy & Security → **Accessibility** must have Hammerspoon enabled (required for typing the cleaned text at the cursor).

### Empty transcript

**Symptom:** Hotkey worked, mic indicator flashed, no text typed. `yappr-trace --summary` shows `len=0` (or `-`) and `audio_ms` small.

This is expected when the user released the hotkey without speaking: `yappr` exits 0, no error alert. If `audio_ms` looks reasonable but `len=0`, check the daemon log for STT errors around that timestamp.

### Audio cropped at the start

**Symptom:** First word of every dictation is clipped or missing.

**Fix:** `yappr-trace --summary` and look at `front_ms`. Healthy is 20–50 ms. >200 ms means something between hotkey-press and `daemon_engine_start_return` is slow — usually daemon cold-start (was it freshly launched?) or contention with another app holding the mic. Drill into the timeline with `yappr-trace`: the offending `Δms` row identifies the culprit (e.g. `daemon_accept` slow → socket-side; `daemon_engine_start_return` slow → AVAudioEngine first-`start()` cost not yet paid).

### TTFT suspiciously high

**Symptom:** `yappr stats` shows `llm_ttft_ms` consistently >300 ms when you expect ~100 ms.

**Diagnosis:** Confirm the active backend caches the system prompt across requests.

```bash
yappr config active                                       # which config?
diagnostics/yappr-probe-caching 10                        # measure TTFT pattern
curl -s http://127.0.0.1:8081/health | jq                 # warm_requests climbing?
```

If `warm_requests` increments on each dictation, caching is working; the latency floor is the model's. If you're pointed at stock `mlx_lm.server` (no cross-request caching), switch:

```bash
yappr config use default
```

### Prompt-hash rebuild on every request

**Symptom:** Server stderr shows `[cache] system prompt changed (got X, had Y) — rebuilding` repeatedly.

If it fires once after you edit `prompts/cleanup.txt`, that's expected and self-healing — one ~150 ms cold prefill, then warm again. If it fires every request, two configs are pointed at the same port with different prompts; check `yappr config active` and your server invocations.

### Model refuses to dictate / outputs "I cannot do that"

**Symptom:** `cleaned_chars` is 0 or the typed text reads like a chatbot refusal.

**Cause:** The cleanup prompt is missing its grounding examples; the model thinks the user is addressing it.

**Fix:** Compare `prompts/cleanup.txt` against the shipped version. The "is this a question" framing examples need to be present so the model stays in transcript-cleaner mode. See `docs/customization.md`.

---

## The cache probe (dev tool)

`diagnostics/yappr-probe-caching` is the verification tool for "does this LLM endpoint reuse KV state across requests". Not part of the dictation runtime — point it at any chat-completions endpoint to characterize caching behavior.

```bash
diagnostics/yappr-probe-caching 10
```

### What it does

1. Loads the active config — uses its LLM URL, params, and system prompt file so test conditions match real cleanup calls.
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

The probe's "is caching working" heuristic expects **lazy** per-request caching (call 1 slow, 2–N fast). `yappr-mlx-server` uses **pre-startup** caching, so *all* calls are warm — the probe will report "no caching" even though it's working correctly.

Actual smoking guns:

1. **Cross-config comparison.** Run the probe on `default` (ours, port 8081), note ~104 ms. Switch to a stock-`mlx_lm.server` config, note ~153 ms. The delta is the win.
2. **Server `/health` stats.** `cold_prefills: 1, warm_requests: N` means the cache was built once at startup and reused N times.

```bash
curl -s http://127.0.0.1:8081/health | jq '{cached_prefix_tokens, cold_prefills: .stats.cold_prefills, warm_requests: .stats.warm_requests}'
```

See `docs/performance.md` for the full methodology.

## Post-install verification: yappr doctor

Run `yappr doctor` to check all components in one step:

```bash
yappr doctor
```

It checks: platform (Apple Silicon), required tools on PATH, XDG dirs, active config validity, daemon binary + codesign, daemon process + socket, LLM endpoint reachability, Nemotron model cache, Hammerspoon installation, and `mlx_lm` availability.

Exit code 0 = all checks passed. Exit code 1 = one or more checks failed (with actionable hints printed).
