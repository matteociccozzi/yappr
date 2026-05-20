# yappr-stt-daemon

Long-running Swift daemon that owns the microphone and runs streaming
Nemotron 0.6B speech-to-text via FluidAudio. Speaks a small Unix-domain
socket protocol. The daemon listens on `$YAPPR_RUNTIME_DIR/stt.sock` (default: `/tmp/yappr-<uid>/stt.sock`): connect to start a session, half-
close write to finalize, read `audio_ms\ttranscript\n` back.

This Swift package ships two executable targets:

- **`YapprSttDaemon`** — the long-running daemon described above.
- **`YapprSttConnect`** — a tiny socket client (no FluidAudio dep, ~5 ms
  startup) that `bin/yappr` spawns to open the daemon socket. SIGTERM (sent
  by Hammerspoon on hotkey release) triggers `shutdown(SHUT_WR)`, after
  which it reads the transcript line back and prints it to stdout.

## Build & run

**Build:**
```bash
# Built by scripts/install.sh automatically. To rebuild manually:
cd swift/yappr-stt-daemon
swift build -c release \
  --scratch-path ~/.local/share/yappr/build/yappr-stt-daemon
```

Binaries land at:
- `~/.local/share/yappr/build/yappr-stt-daemon/release/YapprSttDaemon`
- `~/.local/share/yappr/build/yappr-stt-daemon/release/YapprSttConnect`

```bash
codesign --force --sign - ~/.local/share/yappr/build/yappr-stt-daemon/release/YapprSttDaemon
~/.local/share/yappr/build/yappr-stt-daemon/release/YapprSttDaemon
```

The ad-hoc `codesign` is required for the daemon only (it's the binary that
actually opens the mic). TCC keys microphone permission by code-signing
identity; an unsigned dev binary gets re-prompted on every rebuild. The
`--sign -` flag produces an ad-hoc signature with a stable identity for
this binary, so the permission grant survives rebuilds. `YapprSttConnect`
doesn't touch the mic and doesn't need signing.

## TCC microphone permission

The first time you start the daemon, macOS will show a system prompt asking
to grant microphone access. This fires during the daemon's launch warm-up
(`engine.start()` / brief read / `engine.stop()`), not on your first hotkey
press, so the dialog doesn't block dictation.

If the daemon is silently failing to capture audio, check
`System Settings → Privacy & Security → Microphone` and confirm
`YapprSttDaemon` is enabled. If it isn't listed, reset and re-prompt:

```bash
tccutil reset Microphone
```

then restart the daemon.

## Lifecycle and the mic indicator

The macOS orange dot is a system-level privacy indicator — it lights up
when, and only when, a process actually opens the HAL input stream
(`engine.start()`). The daemon manages it explicitly:

| Phase | Indicator | Notes |
|---|---|---|
| Launch — setup | off | `engine.prepare()`, tap install, model load |
| Launch — warm-up | **on briefly (~100 ms)** | Pays AVAudioEngine's first-`start()` cost (~200–400 ms one-shot) so the user's first dictation is fast |
| Idle | off | Engine prepared but stopped |
| Session (accept → EOF) | on | Mic is actually capturing |
| Session done | off | `engine.stop()` extinguishes the dot |

The launch flash is the only time the dot appears outside a press-to-
release window. If you ever see it on between dictations, something is
wrong — restart the daemon.

## Wire protocol

Single-connection-per-session. The client:

1. `connect("$YAPPR_RUNTIME_DIR/stt.sock")` — daemon accepts and starts the mic.
2. (No payload — audio comes from the mic, not the wire.)
3. `shutdown(SHUT_WR)` — daemon stops the mic and finalizes.
4. Read `<audio_ms>\t<transcript>\n` until EOF, then close.

`audio_ms` is the daemon's authoritative count of 16 kHz mono samples
delivered to the recognizer, in milliseconds.

## Files

- `Sources/YapprSttDaemon/Daemon.swift` — entry point, model load, mic
  prepare + warm-up, accept loop (sessions serialized).
- `Sources/YapprSttDaemon/MicCapture.swift` — actor wrapping
  `AVAudioEngine` + `AVAudioConverter`; install-once tap, nullable session
  continuation.
- `Sources/YapprSttDaemon/Session.swift` — per-connection state machine:
  audio pump + EOF watcher + 60 s timeout, writes `audio_ms\ttranscript\n`.
- `Sources/YapprSttDaemon/UnixSocket.swift` — BSD socket wrapper.
- `Sources/YapprSttDaemon/Log.swift` — minimal logger.
- `Sources/YapprSttDaemon/Trace.swift` — append-only span emitter writing
  TSV rows to `$YAPPR_TRACE_LOG` (default: `/tmp/yappr-<uid>/trace.log`). Mirrors the inline trace helpers in
  `YapprSttConnect/main.swift` and `~/.hammerspoon/init.lua`; together they
  give end-to-end stage timings that `bin/yappr-trace` renders.
- `Sources/YapprSttConnect/main.swift` — the socket client binary.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `YAPPR_RUNTIME_DIR` | `/tmp/yappr-$(id -u)` | Directory for socket, PID, trace |
| `YAPPR_SOCKET` | `$YAPPR_RUNTIME_DIR/stt.sock` | Unix socket path |
| `YAPPR_DAEMON_PID` | `$YAPPR_RUNTIME_DIR/daemon.pid` | PID file |
| `YAPPR_TRACE_LOG` | `$YAPPR_RUNTIME_DIR/trace.log` | Timing trace |
