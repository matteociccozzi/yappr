import Darwin
import Foundation

/// Append-only event tracer. Writes one line per event to the trace log:
///
///     <unix_microseconds> <source> <event> [k1=v1 k2=v2 ...]
///
/// The log path is resolved from YAPPR_TRACE_LOG env var, falling back to
/// <runtimeDir>/trace.log. All writes use `open + write + close` with
/// O_APPEND, which gives atomic appends per syscall on macOS (well under
/// PIPE_BUF = 512 bytes). Safe to call from any thread, including the
/// CoreAudio I/O thread for `first_tap`.
enum Trace {
    static var path: String {
        let env = ProcessInfo.processInfo.environment
        if let t = env["YAPPR_TRACE_LOG"] { return t }
        return "\(YapprSttDaemon.runtimeDir)/trace.log"
    }

    /// Emit one event. `details` is appended verbatim after the event name —
    /// keep it short and use `key=value key=value` form for greppability.
    static func emit(_ event: String, source: String = "daemon", details: String = "") {
        let us = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let line = details.isEmpty
            ? "\(us) \(source) \(event)\n"
            : "\(us) \(source) \(event) \(details)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            _ = data.withUnsafeBytes { buf in
                Darwin.write(fd, buf.baseAddress, data.count)
            }
            _ = Darwin.close(fd)
        }
    }
}
