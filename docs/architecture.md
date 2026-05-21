# 🏗️ Architecture

## Pipeline at a glance

The pipeline has two distinct lifecycles:

- **Long-running**: `YapprSttDaemon` is launched once (at login / by the user)
  and stays resident. It loads Nemotron 0.6B, owns the mic via `AVAudioEngine`,
  and serves push-to-talk sessions over a Unix socket. `bin/yappr-mlx-server`
  similarly stays resident, holding the Qwen3-1.7B-4bit model and the
  prefilled-system-prompt KV cache.
- **Per-dictation**: Hammerspoon spawns `bin/yappr` on hotkey-press; `bin/yappr`
  is a thin subcommand dispatcher that defaults to `bin/yappr-dictate`, which
  spawns `YapprSttConnect`, runs the cleanup LLM, appends a metric, and exits.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  Hammerspoon  (~/.hammerspoon/init.lua)                                      │
│  • Ctrl+Option+Y down → hs.task.new("/bin/bash", "-c YAPPR_QUIET=1 yappr")   │
│  • Ctrl+Option+Y up   → task:terminate()  (SIGTERM to bash)                  │
│  • streamCallback     → hs.eventtap.keyStrokes(chunk) at the cursor          │
└──────────────────────────────────────────────────────────────────────────────┘
                                       │ spawn (bash -c, NOT -lc)
                                       ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  bin/yappr  (subcommand dispatcher)  →  bin/yappr-dictate  (orchestrator)    │
│                                                                              │
│  1. FAST PATH — spawn YapprSttConnect FIRST, in background                   │
│     (connect = daemon opens mic; everything else runs in parallel)           │
│  2. Pre-flight  — load config, hash prompt, optional LLM health-check        │
│  3. Wait        — `wait $STREAM_PID`; SIGTERM trap forwards to the client    │
│  4. Cleanup     — pipe request into yappr-llm-call (streaming SSE)           │
│  5. Metric      — append one JSONL row to $YAPPR_STATE_HOME/metrics/<YYYY-MM>.jsonl            │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
        │                                       │
        │ unix-socket $YAPPR_RUNTIME_DIR/stt.sock        │ HTTP /v1/chat/completions
        │ (control + result)                     │ (streaming SSE)
        ▼                                       ▼
┌────────────────────────────────────┐   ┌────────────────────────────────────┐
│  YapprSttDaemon  (resident, Swift) │   │  bin/yappr-mlx-server (resident,   │
│                                    │   │   Python, MLX, port 8081)          │
│  • connect() ⇒ Session.run         │   │  • startup: prefill system-prompt  │
│  • mic.beginSession() — engine     │   │    KV cache (N tokens, one fwd     │
│    start; AVAudioEngine tap        │   │    pass)                           │
│    delivers 16 kHz mono Float32    │   │  • per request: reset each layer's │
│  • Streaming Nemotron 0.6B         │   │    cache.offset = N, prefill only  │
│    chunks incrementally as audio   │   │    the user-suffix, stream         │
│    flows in                        │   │  • SSE chunks → stdout of          │
│  • Client SHUT_WR ⇒ mic.endSession │   │    yappr-llm-call → bin/yappr      │
│    + manager.finish() → transcript │   │    stdout → Hammerspoon            │
│  • Write "<audio_ms>\\t<text>\\n"    │   │    streamCallback → keystrokes    │
│    and SHUT_WR                     │   │                                    │
└────────────────────────────────────┘   └────────────────────────────────────┘
```

Everything is single-tenant. Sessions are serialized in the daemon; the MLX
server is single-tenant by design (one lock, one shared mutable KV cache).

## The daemon (`swift/yappr-stt-daemon/`)

One Swift package with two executables.

### `YapprSttDaemon` — long-running STT server

`Sources/YapprSttDaemon/Daemon.swift` is `@main`. At launch:

1. Loads the streaming Nemotron 0.6B model via FluidAudio's
   `StreamingNemotronAsrManager` from
   `~/.cache/fluidaudio/models/nemotron-streaming/560ms`.
2. Warms the encoder by feeding two chunks of silence through
   `appendAudio` → `processBufferedAudio` → `finish` → `reset`. The first
   `processChunk` after `loadModels` is ~10× slower than steady-state because
   CoreML compiles and uploads to the ANE; absorbing that cost at startup
   keeps the first user dictation snappy.
3. Calls `MicCapture.prepare()` (installs the tap, builds the AVAudioConverter,
   calls `engine.prepare()` — the HAL stream does **not** open, no mic
   indicator).
4. Calls `MicCapture.warmUp()` — briefly starts and stops the engine to pay
   AVAudioEngine's first-`start()` cost (~200–400 ms first time vs ~10–30 ms
   steady-state). The orange mic dot flashes for ~100 ms. Deliberate, one-time.
5. Binds the Unix socket at `$YAPPR_RUNTIME_DIR/stt.sock` and serializes `accept`
   loops into `Session.run`.

Model and chunk size are compile-time constants on `YapprSttDaemon`
(`chunkSize = .ms560`, `cacheSubdir = "560ms"`). No runtime flags.

### Environment variables consumed by YapprSttDaemon

| Var | What it controls |
|---|---|
| `YAPPR_SOCKET` | Unix socket path (default: `$YAPPR_RUNTIME_DIR/stt.sock`) |
| `YAPPR_RUNTIME_DIR` | Directory for socket, PID, trace (default: `/tmp/yappr-$(id -u)`) |
| `YAPPR_DAEMON_PID` | PID file path (default: `$YAPPR_RUNTIME_DIR/daemon.pid`) |
| `YAPPR_TRACE_LOG` | Timing trace file path (default: `$YAPPR_RUNTIME_DIR/trace.log`) |

`YapprSttConnect` reads `YAPPR_SOCKET` and `YAPPR_TRACE_LOG` via the same mechanism.

### `YapprSttConnect` — tiny socket client

`Sources/YapprSttConnect/main.swift`. ~80 KB binary, ~5 ms cold start, no
FluidAudio dependency. Top-level script-style code (not a `@main` struct) to
shave a few more milliseconds. The behavior is, in order:

1. `socket(AF_UNIX, SOCK_STREAM, 0)` then `connect("$YAPPR_RUNTIME_DIR/stt.sock")` —
   the connect is what tells the daemon to start the mic.
2. Install SIGTERM/SIGINT handler: on signal, `shutdown(fd, SHUT_WR)` and
   stamp `g_t_eof_ns` for finalize-latency reporting. Async-signal-safe; no
   trace write from inside the handler.
3. `read()` until EOF; print transcript on stdout, `audio_ms / finalize_ms /
   total_ms` summary on stderr.

This binary used to be a Python helper; Python startup was 30–50 ms and that
delay is lost audio at the head of every dictation. Swift was the smallest
viable replacement.

### `MicCapture` (`MicCapture.swift`)

Owns the `AVAudioEngine`, the input tap, and an `AVAudioConverter` that
resamples whatever the device delivers down to 16 kHz mono Float32.

- **Buffer-frame-size**: at `prepare()`, sets
  `kAudioDevicePropertyBufferFrameSize = 256` (~5.3 ms) on the default input
  device via HAL property API. `installTap`'s `bufferSize` argument is
  advisory and macOS ignores it for device delivery, so we set the HAL
  property directly. Affects all apps using the device until reset.
- **Single tap, session-scoped continuation**: the tap closure is installed
  once and reused across sessions. When no session is active,
  `currentContinuation == nil` and tap buffers are dropped on the floor.
- **Format-change resilience**: `beginSession()` re-queries the input node's
  `inputFormat(forBus: 0)`. If sample rate or channel count differ from the
  cached `nativeFormat`, the tap is removed, the converter is rebuilt, and
  the tap is reinstalled with the new format. If `engine.start()` still
  returns `kAudioUnitErr_FormatNotSupported (-10868)` (the device changed
  between query and start — possible with AirPods hot-plug etc.), there's a
  one-shot retry that refreshes again and reinstalls.
- **Resampler statefulness**: `convert(to:error:)` is called with the
  callback API and `.noDataNow` (not `.endOfStream`) so the resampler
  retains its tail-sample buffer across ingest calls within a session.
  Using `.endOfStream` flushes-and-resets every call and loses most samples
  to repeated priming.

### `Session` (`Session.swift`)

One push-to-talk session = one `accept()`. The socket is a **control + result
channel**, not a PCM pipe — audio flows from `MicCapture` directly into the
manager, never through the socket.

Wire protocol:

```
Client                                  Daemon
  ─── connect() ───────────────────────►
                                         accept(); mic.beginSession()
                                         (orange dot ON, audio flowing into
                                          the streaming Nemotron manager)
  ─── shutdown(SHUT_WR) ───────────────►
                                         mic.endSession()  (dot OFF)
                                         manager.finish()  (~30 ms)
  ◄── "<audio_ms>\t<transcript>\n" ────
                                         shutdown(SHUT_WR)
  EOF, close, exit
```

`Session.run` opens three concurrent tasks:

- **Audio pump**: `for await buffer in stream { manager.appendAudio;
  manager.processBufferedAudio }`. Driven by the mic; exits when the mic
  finishes the continuation.
- **EOF watcher**: `socket.read` loops until 0 bytes (client SHUT_WR), then
  calls `mic.endSession()` which finishes the stream → pump exits.
- **Timeout** (60 s): if EOF never arrives, force `mic.endSession()` and
  `socket.shutdownReadWrite()` so the daemon doesn't block forever.

After the task group joins, `manager.finish()` returns the final transcript,
which gets written back as `<audio_ms>\t<text>\n` followed by `SHUT_WR`.

Partial transcripts are never written; the client-side `SHUT_WR` is the only
trigger for emitting text.

## `bin/yappr` — subcommand dispatcher

`bin/yappr` is a thin git-style dispatcher. When invoked without a subcommand
(as Hammerspoon does), it defaults to `dictate` and `exec`s `bin/yappr-dictate`.
Other subcommands: `daemon`, `server`, `config`, `stats`, `trace`, `doctor`,
`help`, `version`.

## `bin/yappr-dictate` — bash orchestrator

Entry point for dictation. Hammerspoon invokes `bin/yappr` which dispatches here.
The top-of-file docstring is the authoritative spec; this section is a synopsis.
Stages, in order:

1. **Fast-path socket connect (latency-critical)**. Verify
   `$YAPPR_RUNTIME_DIR/stt.sock` exists, then spawn `YapprSttConnect` in the
   background **before any other work**. The connect is what tells the daemon
   to open the mic. A SIGTERM trap forwards the signal to the client.
2. **Pre-flight (in parallel with recording)**. Load config from
   `$YAPPR_CONFIG` (default `configs/active.json`), pull `llm.url`,
   `model_name`, `max_tokens`, `temperature`, `extra_params`, `version`,
   compute config + prompt hashes, set up the log file, optionally
   health-check the LLM endpoint.
3. **Wait + finalize**. `wait $STREAM_PID`. SIGTERM trap forwards to
   `YapprSttConnect`, which half-closes; daemon finalizes and returns; client
   prints transcript on stdout and `audio_ms=… finalize_ms=… total_ms=…` on
   stderr, which we scrape for the metric.
4. **LLM cleanup**. Build the chat-completions JSON from config, pipe into
   `bin/yappr-llm-call`. The helper's stdout (cleaned text, streamed token
   by token) flows straight through to `bin/yappr`'s stdout — no buffering.
5. **Metric emit**. Append one JSON line to `$YAPPR_STATE_HOME/metrics/<YYYY-MM>.jsonl` with
   `stt_ms`, `stt_total_held_ms`, `llm_ttft_ms`, `llm_total_ms`,
   `audio_seconds`, `prompt_tokens`, `completion_tokens`, hashes, etc.

Output discipline:

- `stdout` = streamed cleaned text. Nothing else.
- `stderr` = diagnostics + final timing report (suppressed when `YAPPR_QUIET=1`).
- `$YAPPR_STATE_HOME/logs/<timestamp>.log` = per-run log file.
- `$YAPPR_STATE_HOME/metrics/<YYYY-MM>.jsonl` = one JSON line per run.

Env vars: `YAPPR_CONFIG`, `YAPPR_QUIET`, `YAPPR_COPY`, `YAPPR_DEBUG`,
`YAPPR_ROOT`. See the in-file docstring.

`set -e` is deliberately off (only `set -uo pipefail`) so a soft failure
still leaves logs we can read.

## `bin/yappr-llm-call` — streaming HTTP helper (Python)

Reads request JSON (`{url, body, timeout}`) from stdin, POSTs the body with
`stream:true`, parses the SSE stream, and:

- Streams each `choices[0].delta.content` chunk to stdout immediately (one
  `sys.stdout.write` + `flush` per chunk).
- Stamps a wall-clock timestamp on the first content chunk — that's the
  real TTFT, not "time to last byte".
- Emits a single-line JSON metric blob on the **last** line of stderr:
  `{text, ttft_ms, total_ms, prompt_tokens, completion_tokens, error?}`.

The reason this exists in Python rather than inline curl: `curl --write-out
time_starttransfer` with `stream:false` measures when the entire response
was delivered, not first-token latency.

## `bin/yappr-mlx-server` — local inference backend (Python)

A custom ~440-line MLX server with **explicit prefix caching**. Stock
`mlx_lm.server` does not preserve a prefilled KV cache across independent
chat-completion requests; this one does.

Mechanism:

```python
# at startup, once
sys_tokens = tokenizer.apply_chat_template(
    [{"role": "system", "content": SYS}],
    tokenize=True, add_generation_prompt=False,
)
master_cache = make_prompt_cache(model)
_ = model(mx.array(sys_tokens)[None], cache=master_cache)
mx.eval([c.state for c in master_cache])
N = len(sys_tokens)
sys_prompt_hash = sha256(SYS)[:12]

# every request
incoming_sys = body["messages"][0]["content"]
if sha256(incoming_sys)[:12] != sys_prompt_hash:
    rebuild(incoming_sys)   # cold path; prompt-file changed without restart

# reset offset back to the prefix boundary; underlying KV tensors stay live
for layer in master_cache:
    layer.offset = N

full_tokens = tokenizer.apply_chat_template(body["messages"],
                                            tokenize=True,
                                            add_generation_prompt=True)
user_tokens = full_tokens[N:]   # only the user-suffix needs new prefill
for chunk in stream_generate(model, tokenizer, user_tokens,
                             prompt_cache=master_cache, sampler=sampler):
    yield_sse(chunk)
```

A `threading.Lock` serializes requests against the shared mutable cache.
Single-tenant by design.

Endpoints:

- `POST /v1/chat/completions` — OpenAI-compatible, supports SSE streaming.
- `GET /v1/models` — includes `cached_prefix_tokens`, `cached_prefix_hash`.
- `GET /health` — `status`, `model`, `cached_prefix_tokens`, `stats.cold_prefills`,
  `stats.warm_requests`.

See [`docs/performance.md`](performance.md) for measured numbers.

**Limitations**:

- Works only for full-attention transformers that support
  `make_prompt_cache(model)` with offset-based truncation. SSM/Mamba/hybrid
  models need a different cache primitive.
- KV cache is RAM-only; server restart pays a fresh cold prefill.

## Telemetry: `$YAPPR_RUNTIME_DIR/trace.log` and `bin/yappr-trace`

Every stage writes append-only events to a single shared log file. Format,
one event per line:

```
<unix_microseconds> <source> <event> [k1=v1 k2=v2 ...]
```

Sources: `hs` (Hammerspoon), `swift` (`YapprSttConnect`), `daemon`
(`YapprSttDaemon`). All writes use `open(O_APPEND) + write + close`, which
gives atomic appends per syscall on macOS (writes are well under
`PIPE_BUF = 512`), so it's safe to call from any thread — including the
CoreAudio I/O thread for the `daemon_first_tap` event.

Representative events:

| Source  | Event                              | Meaning                                       |
| ------- | ---------------------------------- | --------------------------------------------- |
| `hs`    | `hs_press`                         | Hotkey down                                   |
| `hs`    | `hs_task_start_call/return`        | `hs.task.new(bash, …):start()`                |
| `hs`    | `hs_release`                       | Hotkey up (triggers `task:terminate()`)       |
| `swift` | `swift_main`                       | YapprSttConnect process start                 |
| `swift` | `swift_socket_open` / `_connected` | Socket connect milestones                     |
| `swift` | `swift_recv_done`                  | Daemon's response received (bytes=N)          |
| `daemon`| `daemon_accept`                    | `accept()` returned, new session starting     |
| `daemon`| `daemon_begin_session_call/return` | `mic.beginSession()` boundaries               |
| `daemon`| `daemon_engine_start_call/return`  | `AVAudioEngine.start()` boundaries            |
| `daemon`| `daemon_first_tap`                 | First tap callback fires (frames=N)           |
| `daemon`| `daemon_eof_received`              | Client SHUT_WR observed                       |
| `daemon`| `daemon_finish_call/return`        | `manager.finish()` boundaries                 |
| `daemon`| `daemon_write_done`                | Transcript written to socket                  |

`bin/yappr-trace` renders sessions with deltas and phase grouping. A
"session" is a contiguous run of events with < 10 s gaps between them. The
phases are:

```
PHASES = ["hammerspoon", "spawn", "daemon-setup", "capture", "finalize"]
```

Usage: `yappr-trace` (last session), `yappr-trace --last N` (last N).

## Other binaries

| Binary                   | Role                                                        |
| ------------------------ | ----------------------------------------------------------- |
| `bin/yappr-daemon`       | Lifecycle manager for YapprSttDaemon: `start / stop / restart / status / logs / tail`. Reads paths from `_yappr-paths.sh`. |
| `bin/yappr-server`       | Lifecycle manager for the MLX inference server: `start / stop / restart / status / logs / tail`. Reads model/port/prompt from active config. |
| `bin/yappr-config`       | Atomic symlink-based config switching (`list / active / use NAME / show / diff / delete / path`). See [`configuration.md`](configuration.md). |
| `bin/yappr-stats`        | Reads `$YAPPR_STATE_HOME/metrics/*.jsonl`; default view = last-20-run summary with mean / p50 / p95 / max + histograms + A/B comparisons. See [`metrics.md`](metrics.md). |
| `bin/yappr-trace`        | Renders `$YAPPR_RUNTIME_DIR/trace.log` (above). |
| `bin/yappr-doctor`       | Post-install health verifier. Runs 11 checks (platform, PATH, XDG dirs, config, daemon binary + codesign, daemon process + socket, LLM endpoint, Nemotron cache, Hammerspoon, mlx_lm). Exits 1 on any failure. |
| `bin/yappr-help`         | Prints git-style subcommand listing with env var overrides table and docs links. |
| `bin/yappr-mlx-server`   | Bash launcher for `yappr-mlx-server.py`. Resolves the uv-managed Python interpreter at runtime; falls back to `python3`. |
| `bin/_yappr-paths.sh`    | Single source of truth for all `YAPPR_*` env vars (bash). Sourced by every bash script. Defines `yappr_ensure_dirs`, `yappr_metric_path`, `yappr_log_path`, `yappr_connect_binary`, `yappr_daemon_binary`. |
| `bin/_yappr_paths.py`    | Python counterpart to `_yappr-paths.sh`. Imported by every Python script (`import _yappr_paths as paths`). Exposes `root()`, `config_home()`, `state_home()`, `runtime_dir()`, `socket()`, `trace_log()`, `metrics_dir()`, `logs_dir()`, `config_file()`, `daemon_binary()`, `connect_binary()`, `ensure_dirs()`. |

### Internal dev tools (not in `bin/`)

- `diagnostics/yappr-probe-caching` — A/B cache probe. Hits an LLM endpoint
  N times with the same system prompt and varied tiny user messages and
  reports per-call TTFT. Used to verify a backend is actually prefix-caching.
  See [`diagnostics.md`](diagnostics.md).

## End-to-end streaming path

What makes text appear at the cursor while the LLM is still generating:

1. `yappr-mlx-server` flushes each SSE chunk immediately after generating it.
2. `yappr-llm-call` reads the stream line by line, writes each
   `delta.content` to `sys.stdout` and flushes.
3. `bin/yappr` does not capture or buffer the helper's stdout — it inherits
   straight through to `bin/yappr`'s own stdout.
4. Hammerspoon's `hs.task` `streamCallback` fires on each write; each chunk
   is passed to `hs.eventtap.keyStrokes(chunk)`, which synthesizes character
   key events at the cursor.

The clipboard is **never** read and **never** written by default. (Set
`YAPPR_COPY=1` to also `pbcopy` the cleaned text after the stream completes;
this is for CLI use, not the Hammerspoon path.)

## Hammerspoon integration (`~/.hammerspoon/init.lua`)

Hold Ctrl+Option+Y to dictate. Press = spawn `bin/yappr`; release =
`task:terminate()` (SIGTERM). The task is spawned with `/bin/bash -c` —
**not** `-lc`. A login shell sources `~/.profile` on every invocation,
which on this system adds ~640 ms before `bin/yappr` even starts — all of
it lost audio at the front of the dictation. PATH is set inline in the
command instead.

## Why bash for the orchestrator?

The orchestrator's job is shell glue — spawn processes, manage env vars,
pipe stdin/stdout, append to files. Bash is the right tool. The
latency-sensitive bits (socket client, mic, streaming STT) live in Swift;
the protocol-y bits (SSE parsing, KV-cache tricks) live in Python.
