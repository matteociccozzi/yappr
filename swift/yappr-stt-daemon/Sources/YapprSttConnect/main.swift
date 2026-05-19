import Darwin
import Foundation

// Append a telemetry event to /tmp/yappr-trace.log. Format mirrors the
// daemon's Trace.swift so all rows share one file/format.
func trace(_ event: String, _ details: String = "") {
    let us = Int64(Date().timeIntervalSince1970 * 1_000_000)
    let line = details.isEmpty
        ? "\(us) swift \(event)\n"
        : "\(us) swift \(event) \(details)\n"
    guard let data = line.data(using: .utf8) else { return }
    let fd = Darwin.open("/tmp/yappr-trace.log", O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if fd >= 0 {
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        _ = Darwin.close(fd)
    }
}

trace("swift_main")

// yappr-stt-connect — tiny socket client for yappr-stt-daemon.
//
// Connects to /tmp/yappr-stt.sock (which causes the daemon to start the mic
// and begin a session), waits for SIGTERM/SIGINT to half-close the write side
// (which causes the daemon to stop the mic and finalize), then reads the
// "<audio_ms>\t<transcript>\n" response and prints:
//   stdout: transcript (raw text)
//   stderr: "[yappr-stream] audio_ms=N finalize_ms=M total_ms=K"
//
// Replaces the inline python helper in bin/yappr. Python startup was 30-50 ms
// (latency-critical — the socket connect is what tells the daemon to open the
// mic, so anything before connect is lost audio). Swift binary startup is
// 3-8 ms.

let SOCK_PATH = "/tmp/yappr-stt.sock"

// Signal-shared state — flag + write fd. Both must be accessible from the
// async-signal-safe handler, so they're file-scope globals.
nonisolated(unsafe) var g_fd: Int32 = -1
nonisolated(unsafe) var g_signaled: Int32 = 0
nonisolated(unsafe) var g_t_eof_ns: UInt64 = 0

func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

let tStart = nowNs()

// Open the socket FIRST. The daemon opens the mic when we connect, so we
// want this as the very first non-trivial syscall in the program.
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
if fd < 0 {
    FileHandle.standardError.write(Data("[yappr-stream] socket() failed: errno=\(errno)\n".utf8))
    exit(1)
}
g_fd = fd
trace("swift_socket_open")

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(SOCK_PATH.utf8)
withUnsafeMutableBytes(of: &addr.sun_path) { dst in
    for (i, b) in pathBytes.enumerated() { dst[i] = b }
    dst[pathBytes.count] = 0
}
let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
let connRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
        Darwin.connect(fd, sp, addrLen)
    }
}
if connRC < 0 {
    FileHandle.standardError.write(Data("[yappr-stream] connect failed: errno=\(errno)\n".utf8))
    trace("swift_connect_error", "errno=\(errno)")
    exit(1)
}
trace("swift_connected")

// SIGTERM/SIGINT: half-close the write side. The handler runs in a signal
// context, so it must be async-signal-safe — only shutdown() + a stored
// timestamp.
//
// `nowNs()` calls DispatchTime which uses mach_absolute_time(), which IS
// async-signal-safe on Darwin. shutdown() is safe per POSIX.
let handler: @convention(c) (Int32) -> Void = { _ in
    if g_signaled == 0 {
        g_signaled = 1
        g_t_eof_ns = DispatchTime.now().uptimeNanoseconds
        _ = Darwin.shutdown(g_fd, Int32(SHUT_WR))
        // Skip trace() from the signal handler — file I/O isn't strictly
        // async-signal-safe. The sigterm event will be inferred from the gap
        // between swift_connected and swift_recv_done in the trace viewer.
    }
}
signal(SIGTERM, handler)
signal(SIGINT, handler)

// Block reading until the daemon finishes the transcript and closes its
// write side.
var responseBytes = [UInt8]()
var chunk = [UInt8](repeating: 0, count: 8192)
while true {
    let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 8192) }
    if n == 0 { break }
    if n < 0 {
        if errno == EINTR { continue }
        FileHandle.standardError.write(Data("[yappr-stream] read error: errno=\(errno)\n".utf8))
        break
    }
    responseBytes.append(contentsOf: chunk.prefix(n))
}
let tDone = nowNs()
trace("swift_recv_done", "bytes=\(responseBytes.count)")
_ = Darwin.close(fd)
g_fd = -1

// Parse "<audio_ms>\t<transcript>\n".
var line = String(decoding: responseBytes, as: UTF8.self)
if line.hasSuffix("\n") { line.removeLast() }
var audioMs = 0
var transcript = line
if let tabIdx = line.firstIndex(of: "\t") {
    let head = String(line[..<tabIdx])
    let rest = String(line[line.index(after: tabIdx)...])
    if let n = Int(head) {
        audioMs = n
        transcript = rest
    }
}

let finalizeMs: Int = {
    guard g_t_eof_ns > 0 else { return 0 }
    return Int((tDone &- g_t_eof_ns) / 1_000_000)
}()
let totalMs = Int((tDone &- tStart) / 1_000_000)

FileHandle.standardError.write(Data("[yappr-stream] audio_ms=\(audioMs) finalize_ms=\(finalizeMs) total_ms=\(totalMs)\n".utf8))
FileHandle.standardOutput.write(Data(transcript.utf8))
