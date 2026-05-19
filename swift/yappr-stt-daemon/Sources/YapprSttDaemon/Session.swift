@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// One push-to-talk session. The socket is now a control + result channel,
/// not a PCM pipe — audio comes from `MicCapture` (AVAudioEngine in-process).
///
/// Wire contract:
///   Client connects, immediately half-closes its write side (or sends nothing
///   and half-closes on hotkey release). Daemon captures audio from the mic
///   between accept and the client's SHUT_WR. On EOF, daemon writes one line:
///       "<audio_ms>\t<transcript>\n"
///   then half-closes its write side and the connection ends.
///
/// Partial transcripts are never written. The hotkey-release (= client
/// SHUT_WR) is the only trigger for emitting text.
enum Session {
    /// Hard cap from session start. If the client never half-closes (e.g. it
    /// crashed), force the mic off so the indicator extinguishes and the
    /// daemon doesn't block forever on the next accept.
    static let timeoutSeconds: UInt64 = 60

    static func run(socket: UnixSocket, manager: StreamingNemotronAsrManager, mic: MicCapture) async {
        Trace.emit("daemon_accept")
        let startNs = DispatchTime.now().uptimeNanoseconds
        await manager.reset()
        Trace.emit("daemon_manager_reset_done")

        let stream: AsyncStream<AVAudioPCMBuffer>
        do {
            Trace.emit("daemon_begin_session_call")
            stream = try await mic.beginSession()
            Trace.emit("daemon_begin_session_return")
        } catch {
            Log.error("mic.beginSession failed: \(error)")
            Trace.emit("daemon_begin_session_error", details: "err=\(error)")
            socket.shutdownWrite()
            return
        }

        // Three concurrent tasks:
        //   A. audio pump: stream → manager
        //   B. EOF watcher: read socket until client SHUT_WR
        //   C. timeout: if B doesn't fire in 60s, force everything down
        // Whichever of B or C fires first calls mic.endSession(), which
        // finishes the stream → A exits. We waitForAll, then finalize.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    for await buffer in stream {
                        try await manager.appendAudio(buffer)
                        try await manager.processBufferedAudio()
                    }
                } catch {
                    Log.error("audio pump failed: \(error)")
                }
            }

            group.addTask {
                while true {
                    do {
                        guard let _ = try socket.read(maxBytes: 256) else {
                            break  // EOF — client half-closed
                        }
                        // Client shouldn't send data, but if it does, discard.
                    } catch {
                        Log.warn("EOF watcher read error: \(error)")
                        break
                    }
                }
                Trace.emit("daemon_eof_received")
                await mic.endSession()
                Trace.emit("daemon_engine_stop_returned")
            }

            let timeout = Task {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                Log.warn("session timeout after \(timeoutSeconds)s; forcing mic stop and socket shutdown")
                await mic.endSession()
                socket.shutdownReadWrite()  // unblocks the EOF watcher's read
            }

            await group.waitForAll()
            timeout.cancel()
        }

        let finalizeStartNs = DispatchTime.now().uptimeNanoseconds
        Trace.emit("daemon_finish_call")
        let transcript: String
        do {
            transcript = try await manager.finish()
        } catch {
            Log.error("manager.finish failed: \(error)")
            Trace.emit("daemon_finish_error", details: "err=\(error)")
            socket.shutdownWrite()
            return
        }
        Trace.emit("daemon_finish_return", details: "len=\(transcript.count)")

        let sampleCount = await mic.sampleCount()
        let audioMs = sampleCount * 1000 / 16_000
        let finalizeMs = (DispatchTime.now().uptimeNanoseconds - finalizeStartNs) / 1_000_000
        let totalMs = (DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
        Log.info("session done: audio_ms=\(audioMs) finalize=\(finalizeMs)ms total=\(totalMs)ms")

        var out = Data("\(audioMs)\t".utf8)
        out.append(Data(transcript.utf8))
        out.append(0x0a)
        do {
            try socket.writeAll(out)
        } catch {
            Log.error("socket write failed: \(error)")
        }
        socket.shutdownWrite()
        Trace.emit("daemon_write_done", details: "audio_ms=\(audioMs)")
    }
}
