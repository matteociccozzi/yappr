@preconcurrency import AVFoundation
import CoreAudio
import Foundation

// AVAudioPCMBuffer is not Sendable in Swift 6 (Apple hasn't audited
// AVFoundation yet). We hand-off ownership of each buffer cleanly (the tap
// closure allocates a fresh copy → posts to the actor → actor reads it on
// one thread → yields into a single-consumer stream → consumer reads it),
// so the @unchecked conformance is safe for our use pattern.
extension AVAudioPCMBuffer: @retroactive @unchecked Sendable {}

/// Owns the AVAudioEngine, the input tap, and the format converter. One
/// instance per daemon, created at launch.
///
/// Lifecycle:
///   `prepare()` once at daemon launch — installs the tap, builds the
///   converter, calls `engine.prepare()`. Does NOT start the engine, so no
///   mic indicator and no HAL stream open.
///
///   `warmUp()` once at daemon launch (after prepare) — briefly starts and
///   stops the engine to pay AVAudioEngine's first-`start()` cost (~200–400
///   ms first time vs ~10–30 ms steady-state). The orange mic dot flashes
///   for ~100 ms during this window. Documented, deliberate.
///
///   `beginSession()` per session — resets state, starts the engine. Mic
///   indicator turns on. Tap buffers start flowing into the returned stream.
///
///   `endSession()` per session — finishes the stream, stops the engine.
///   Indicator turns off.
///
/// The tap closure is installed once and never removed; it nil-checks the
/// session continuation and drops buffers when no session is active.
actor MicCapture {
    static let targetSampleRate: Double = 16_000

    static let targetFormat: AVAudioFormat = {
        guard let f = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("could not create 16kHz mono Float32 AVAudioFormat")
        }
        return f
    }()

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var nativeFormat: AVAudioFormat?
    private var tapInstalled = false
    private var tapDiagnostic: TapDiagnostic?

    private var currentContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var currentSampleCount: Int = 0
    private var currentIngestCount: Int = 0
    /// 0 until the first tap fires in a session; 1 thereafter. Reset in
    /// `beginSession()`. Used by the tap closure to emit `daemon_first_tap`
    /// exactly once per session, from the I/O thread.
    private let firstTapFlag = FirstTapFlag()

    func prepare() throws {
        // Shrink the input device's hardware buffer to ~5 ms before AVAudioEngine
        // hooks into it. `installTap`'s `bufferSize` parameter is advisory and
        // macOS ignores it for device delivery; what actually controls "how long
        // does the HAL fill a buffer before delivering the first tap callback"
        // is `kAudioDevicePropertyBufferFrameSize` on the AudioDevice. Default
        // is typically 4800 frames (100 ms @ 48 kHz). 256 frames is ~5.3 ms.
        if let device = Self.defaultInputDeviceID() {
            let chosen = Self.setBufferFrameSize(device: device, target: 256)
            Log.info("input device buffer frame size: requested 256, got \(chosen) frames")
        } else {
            Log.warn("could not find default input device; buffer size left at HAL default")
        }

        let inputNode = engine.inputNode
        let native = inputNode.inputFormat(forBus: 0)
        self.nativeFormat = native
        Log.info("mic native input format: \(native.sampleRate) Hz, \(native.channelCount) ch, common=\(native.commonFormat.rawValue), interleaved=\(native.isInterleaved)")

        guard let conv = AVAudioConverter(from: native, to: MicCapture.targetFormat) else {
            throw MicCaptureError.converterCreate
        }
        self.converter = conv

        self.tapDiagnostic = TapDiagnostic()
        installTap(format: native)
        engine.prepare()
    }

    /// Install (or re-install) the input tap with the given format. Called
    /// from `prepare()` and again from `beginSession()` whenever the device's
    /// native format has changed since the last install — required because
    /// `engine.start()` returns kAudioUnitErr_FormatNotSupported (-10868) if
    /// the tap's format no longer matches what the device is delivering.
    private func installTap(format: AVAudioFormat) {
        let inputNode = engine.inputNode
        if tapInstalled {
            inputNode.removeTap(onBus: 0)
        }
        let counter = self.tapDiagnostic
        let flag = self.firstTapFlag
        inputNode.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            if flag.markIfFirst() {
                Trace.emit("daemon_first_tap", details: "frames=\(buffer.frameLength)")
            }
            counter?.tick(frames: Int(buffer.frameLength))
            guard let self else { return }
            // The tap reuses its buffer storage after the closure returns, so
            // we must copy before handing it off to another execution context.
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
                return
            }
            copy.frameLength = buffer.frameLength
            if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
                let frames = Int(buffer.frameLength)
                let chans = Int(buffer.format.channelCount)
                for c in 0..<chans {
                    memcpy(dst[c], src[c], frames * MemoryLayout<Float>.size)
                }
            } else {
                Log.warn("tap buffer has no floatChannelData (format=\(buffer.format))")
            }
            Task { await self.ingest(copy) }
        }
        tapInstalled = true
    }

    /// Briefly start/stop the engine to pay AVAudioEngine's first-`start()`
    /// cost upfront. Mic indicator flashes ~100 ms. Buffers captured during
    /// this window are discarded because `currentContinuation` is nil.
    func warmUp() async throws {
        try engine.start()
        try? await Task.sleep(nanoseconds: 100_000_000)
        engine.stop()
    }

    /// Begin a new session. Returns an AsyncStream of 16 kHz mono Float32
    /// buffers. Engine starts (mic indicator turns on). Caller must consume
    /// the stream and eventually call `endSession()`.
    func beginSession() throws -> AsyncStream<AVAudioPCMBuffer> {
        // The device's native format can change between sessions if another
        // app opens the mic with a different format, a device is hot-plugged,
        // or the system default input changes. If we don't rebuild the tap to
        // match, engine.start() returns kAudioUnitErr_FormatNotSupported
        // (-10868). Re-query and reinstall if it differs.
        let inputNode = engine.inputNode
        let current = inputNode.inputFormat(forBus: 0)
        if let cached = nativeFormat,
           current.sampleRate != cached.sampleRate || current.channelCount != cached.channelCount {
            Log.info("input format changed: \(cached.sampleRate)→\(current.sampleRate) Hz, \(cached.channelCount)→\(current.channelCount) ch — rebuilding tap + converter")
            guard let conv = AVAudioConverter(from: current, to: MicCapture.targetFormat) else {
                throw MicCaptureError.converterCreate
            }
            converter = conv
            nativeFormat = current
            installTap(format: current)
        }
        converter?.reset()
        currentSampleCount = 0
        currentIngestCount = 0
        tapDiagnostic?.reset()
        firstTapFlag.reset()

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        currentContinuation = continuation

        // Try to start. If we get FormatNotSupported (-10868), the device may
        // have changed format BETWEEN our query above and the actual start —
        // rare but possible. Re-query, rebuild, retry once.
        do {
            Trace.emit("daemon_engine_start_call")
            try engine.start()
            Trace.emit("daemon_engine_start_return")
        } catch let error as NSError where error.code == -10868 {
            currentContinuation = nil
            continuation.finish()
            let refreshed = inputNode.inputFormat(forBus: 0)
            Log.warn("engine.start() got -10868; refreshed format=\(refreshed.sampleRate) Hz, \(refreshed.channelCount) ch — reinstalling tap and retrying")
            guard let conv = AVAudioConverter(from: refreshed, to: MicCapture.targetFormat) else {
                throw MicCaptureError.converterCreate
            }
            converter = conv
            nativeFormat = refreshed
            installTap(format: refreshed)

            let (retryStream, retryCont) = AsyncStream<AVAudioPCMBuffer>.makeStream(
                bufferingPolicy: .bufferingNewest(64)
            )
            currentContinuation = retryCont
            try engine.start()
            return retryStream
        }
        return stream
    }

    /// Finish the current session: finish the continuation (so consumer's
    /// `for await` exits) BEFORE stopping the engine so in-flight tap buffers
    /// either yield cleanly or get dropped by the nil-check. Mic indicator
    /// extinguishes when `engine.stop()` returns.
    func endSession() {
        let (taps, tapFrames) = tapDiagnostic?.snapshot() ?? (0, 0)
        Log.info("session telemetry: tap_fires=\(taps) tap_frames_native=\(tapFrames) ingest_calls=\(currentIngestCount) converted_samples_16k=\(currentSampleCount)")
        currentContinuation?.finish()
        currentContinuation = nil
        if engine.isRunning {
            engine.stop()
        }
    }

    /// Total 16 kHz-mono samples yielded into the current/last session.
    /// Caller computes audio_ms = sampleCount * 1000 / 16000.
    func sampleCount() -> Int {
        currentSampleCount
    }

    // MARK: - CoreAudio HAL helpers (buffer-frame-size control)

    /// Query CoreAudio for the default input device. Returns nil if the query
    /// fails (e.g. no input device is plugged in).
    nonisolated static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    /// Set the device's hardware buffer frame size. Returns the actual size in
    /// effect after the call (may differ from `target` if the device clamps it
    /// to a supported value). Setting this affects every app using the device
    /// until the device default is restored.
    nonisolated static func setBufferFrameSize(device: AudioDeviceID, target: UInt32) -> UInt32 {
        var setSize = target
        var setAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let setStatus = AudioObjectSetPropertyData(
            device, &setAddress, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &setSize
        )
        if setStatus != noErr {
            Log.warn("AudioObjectSetPropertyData(BufferFrameSize=\(target)) failed: \(setStatus)")
        }

        // Read back what's actually in effect now.
        var actual: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var getAddress = setAddress
        let getStatus = AudioObjectGetPropertyData(
            device, &getAddress, 0, nil, &size, &actual
        )
        return getStatus == noErr ? actual : target
    }

    /// Called by the tap closure (via Task hop) for every captured buffer.
    /// Converts to 16 kHz mono Float32 and yields. Drops if no active session.
    private func ingest(_ buffer: AVAudioPCMBuffer) {
        currentIngestCount += 1
        guard let continuation = currentContinuation, let converter else { return }

        // Sample-rate conversion is stateful — the resampler buffers tail
        // samples between calls. We use the callback API with `.noDataNow`
        // (NOT `.endOfStream`) so the resampler retains state across ingest
        // calls within a session. `.endOfStream` would flush+reset every time
        // and we'd lose most samples to repeated priming.
        let ratio = MicCapture.targetSampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 256)
        guard let output = AVAudioPCMBuffer(pcmFormat: MicCapture.targetFormat, frameCapacity: outCapacity) else {
            return
        }

        let state = ConvertState(buffer: buffer)
        var convError: NSError?
        let status = converter.convert(to: output, error: &convError) { _, outStatus in
            if state.inputProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            state.inputProvided = true
            outStatus.pointee = .haveData
            return state.buffer
        }

        if status == .error || convError != nil {
            Log.warn("converter error: \(convError?.localizedDescription ?? "unknown")")
            return
        }
        if output.frameLength == 0 {
            return
        }

        currentSampleCount += Int(output.frameLength)
        continuation.yield(output)
    }
}

/// Mutable state shared between `ingest` and its `convert(...)` callback.
/// A class wrapper keeps the closure capture Sendable-clean (the callback is
/// `@Sendable` in Swift 6 even though `convert` runs it synchronously).
private final class ConvertState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var inputProvided: Bool = false
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// Single-set flag used by the audio I/O thread to fire `daemon_first_tap`
/// exactly once per session. `OSAtomicCompareAndSwap32` would also work but
/// NSLock is simpler and the contention is exactly zero (one writer, never
/// concurrent with itself).
final class FirstTapFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var marked: Bool = false

    /// Returns true exactly once per `reset()` cycle. Subsequent calls return
    /// false. Thread-safe.
    func markIfFirst() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if marked { return false }
        marked = true
        return true
    }

    func reset() {
        lock.lock(); marked = false; lock.unlock()
    }
}

/// Lock-free counters for tap closure diagnostics. Lives outside the actor so
/// the tap closure (CoreAudio I/O thread) can update it without hopping.
final class TapDiagnostic: @unchecked Sendable {
    private let lock = NSLock()
    private var fires: Int = 0
    private var frames: Int = 0

    func tick(frames f: Int) {
        lock.lock()
        fires += 1
        frames += f
        lock.unlock()
    }

    func snapshot() -> (Int, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (fires, frames)
    }

    func reset() {
        lock.lock()
        fires = 0
        frames = 0
        lock.unlock()
    }
}

enum MicCaptureError: Error, CustomStringConvertible {
    case converterCreate
    var description: String {
        switch self {
        case .converterCreate: return "could not create AVAudioConverter (input format → 16 kHz mono Float32)"
        }
    }
}
