import AVFoundation
import Darwin
import FluidAudio
import Foundation

@main
struct YapprSttDaemon {
    /// Runtime directory resolved from YAPPR_RUNTIME_DIR env var, falling back
    /// to /tmp/yappr-<uid> to avoid collisions on multi-user machines.
    static var runtimeDir: String {
        let env = ProcessInfo.processInfo.environment
        if let d = env["YAPPR_RUNTIME_DIR"] { return d }
        return "/tmp/yappr-\(getuid())"
    }

    /// Unix socket path resolved from YAPPR_SOCKET env var, falling back to
    /// <runtimeDir>/stt.sock.
    static var socketPath: String {
        let env = ProcessInfo.processInfo.environment
        if let s = env["YAPPR_SOCKET"] { return s }
        return "\(runtimeDir)/stt.sock"
    }

    /// Hard-coded model choice. Phase 0 A/B picked Nemotron 0.6B at 560 ms chunks.
    /// To switch engines, change these two lines and rebuild — there is no runtime flag.
    static let chunkSize: NemotronChunkSize = .ms560
    static let cacheSubdir = "560ms"

    static func main() async {
        Log.info("yappr-stt-daemon starting (Nemotron 0.6B @ \(chunkSize.rawValue)ms)")

        installSignalHandlers()

        let manager = StreamingNemotronAsrManager(requestedChunkSize: chunkSize)
        do {
            let cacheDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/fluidaudio/models/nemotron-streaming")
                .appendingPathComponent(cacheSubdir)
            try await manager.loadModels(from: cacheDir)
            Log.info("models loaded from \(cacheDir.path)")
        } catch {
            Log.error("model load failed: \(error). Run `fluidaudiocli nemotron-transcribe --input X --chunk \(chunkSize.rawValue)` once to populate the cache.")
            exit(1)
        }

        // Warm the encoder. The first processChunk after loadModels is ~10× slower
        // than steady-state (CoreML compilation + ANE upload); paying that cost on
        // the user's first dictation would stall the pipeline.
        do {
            let warmStartNs = DispatchTime.now().uptimeNanoseconds
            let samples = 8960 * 2  // ~2 chunks of silence at 560 ms
            guard let buf = AVAudioPCMBuffer(pcmFormat: MicCapture.targetFormat, frameCapacity: AVAudioFrameCount(samples)) else {
                throw WarmupError.bufferAlloc
            }
            buf.frameLength = AVAudioFrameCount(samples)
            if let ch = buf.floatChannelData?[0] {
                for i in 0..<samples { ch[i] = 0 }
            }
            try await manager.appendAudio(buf)
            try await manager.processBufferedAudio()
            _ = try await manager.finish()
            await manager.reset()
            let warmMs = (DispatchTime.now().uptimeNanoseconds - warmStartNs) / 1_000_000
            Log.info("encoder warmed (\(warmMs) ms)")
        } catch {
            Log.warn("encoder warm-up failed: \(error); first session will absorb the cold start")
        }

        // Set up the mic. prepare() installs the tap and primes the engine
        // without opening the HAL stream — no mic indicator yet. warmUp()
        // briefly starts/stops the engine to amortize AVAudioEngine's first-
        // start cost (~200–400 ms first time vs ~10–30 ms steady-state). The
        // orange dot flashes for ~100 ms here; this is the only time the
        // indicator appears outside a press-to-release window.
        let mic = MicCapture()
        do {
            try await mic.prepare()
            Log.info("mic prepared (tap installed, engine ready)")
        } catch {
            Log.error("mic prepare failed: \(error); the daemon cannot record without it")
            exit(1)
        }
        do {
            let warmStartNs = DispatchTime.now().uptimeNanoseconds
            try await mic.warmUp()
            let warmMs = (DispatchTime.now().uptimeNanoseconds - warmStartNs) / 1_000_000
            Log.info("mic warmed (\(warmMs) ms); ready for sessions")
        } catch {
            Log.warn("mic warm-up failed: \(error); first session will absorb the cold start")
        }

        // Ensure runtime directory exists with restricted permissions (700)
        // before trying to create the socket or PID file inside it.
        let fm = FileManager.default
        try? fm.createDirectory(
            atPath: Self.runtimeDir,
            withIntermediateDirectories: true,
            attributes: [FileAttributeKey.posixPermissions: NSNumber(value: Int16(0o700))]
        )

        // Write PID file so shell wrappers can track the daemon process.
        let pidPath = ProcessInfo.processInfo.environment["YAPPR_DAEMON_PID"]
            ?? "\(Self.runtimeDir)/daemon.pid"
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(
            toFile: pidPath, atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(atPath: pidPath) }

        let listener: UnixSocket
        do {
            listener = try bindAndListen(at: socketPath)
            Log.info("listening on \(socketPath)")
        } catch {
            Log.error("could not bind socket: \(error)")
            exit(1)
        }

        // Sessions are serialized: accept one, drive it to completion, accept the
        // next. The manager has shared state (audio buffer, encoder cache) and
        // the mic is a single-capture hardware resource — neither tolerates
        // concurrent sessions.
        while true {
            do {
                let conn = try acceptConnection(on: listener)
                await Session.run(socket: conn, manager: manager, mic: mic)
            } catch {
                Log.error("accept failed: \(error)")
                // Don't exit on transient accept errors; just log and keep going.
            }
        }
    }

    enum WarmupError: Error {
        case bufferAlloc
    }

    private static func installSignalHandlers() {
        // Default SIGTERM/SIGINT behavior (terminate) is fine; deinit on the
        // listener UnixSocket closes the fd. The unlink-on-bind on next startup
        // takes care of the stale socket file.
        signal(SIGPIPE, SIG_IGN)  // never crash on broken-pipe writes
    }
}
