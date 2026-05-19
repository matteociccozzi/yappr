import Darwin
import Foundation

/// Thin wrapper around a BSD unix-domain stream socket.
/// Owns the file descriptor and closes it on `close()`.
///
/// `@unchecked Sendable`: the kernel makes read/write/shutdown thread-safe on
/// BSD sockets — the timeout task intentionally calls `shutdownReadWrite()`
/// while another task is blocked on `read()` to unblock it. The fd itself is
/// `let` and the deinit-close races are no worse than they'd be for a struct.
final class UnixSocket: @unchecked Sendable {
    let fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        if fd >= 0 {
            _ = Darwin.close(fd)
        }
    }

    /// Read up to `count` bytes. Returns nil on EOF, throws on error.
    func read(maxBytes: Int) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let n = buffer.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress, maxBytes)
        }
        if n == 0 {
            return nil
        }
        if n < 0 {
            throw SocketError.read(errno)
        }
        return Data(buffer.prefix(n))
    }

    /// Write all bytes. Throws on error.
    func writeAll(_ data: Data) throws {
        var written = 0
        try data.withUnsafeBytes { raw in
            while written < data.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: written), data.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.write(errno)
                }
                written += n
            }
        }
    }

    func shutdownWrite() {
        _ = Darwin.shutdown(fd, Int32(SHUT_WR))
    }

    /// Force-shutdown both directions. Used by the session timeout to unblock
    /// a `read()` that's stuck waiting on a client that crashed without
    /// half-closing. The deinit will still close() the fd.
    func shutdownReadWrite() {
        _ = Darwin.shutdown(fd, Int32(SHUT_RDWR))
    }
}

enum SocketError: Error, CustomStringConvertible {
    case bind(Int32)
    case listen(Int32)
    case accept(Int32)
    case read(Int32)
    case write(Int32)
    case createSocket(Int32)
    case pathTooLong(String)

    var description: String {
        switch self {
        case .bind(let e): return "bind: \(String(cString: strerror(e))) (errno=\(e))"
        case .listen(let e): return "listen: \(String(cString: strerror(e))) (errno=\(e))"
        case .accept(let e): return "accept: \(String(cString: strerror(e))) (errno=\(e))"
        case .read(let e): return "read: \(String(cString: strerror(e))) (errno=\(e))"
        case .write(let e): return "write: \(String(cString: strerror(e))) (errno=\(e))"
        case .createSocket(let e): return "socket: \(String(cString: strerror(e))) (errno=\(e))"
        case .pathTooLong(let p): return "socket path too long for sockaddr_un: \(p)"
        }
    }
}

/// Bind and listen on a unix-domain stream socket at `path`.
/// Removes any stale socket file at that path before binding.
func bindAndListen(at path: String, backlog: Int32 = 4) throws -> UnixSocket {
    unlink(path)  // best effort; ignore ENOENT etc.

    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 {
        throw SocketError.createSocket(errno)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1  // leave room for NUL
    guard pathBytes.count <= maxLen else {
        Darwin.close(fd)
        throw SocketError.pathTooLong(path)
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        for (i, b) in pathBytes.enumerated() {
            dst[i] = b
        }
        dst[pathBytes.count] = 0
    }

    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bindRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            Darwin.bind(fd, sockPtr, addrLen)
        }
    }
    if bindRC < 0 {
        let e = errno
        Darwin.close(fd)
        throw SocketError.bind(e)
    }

    if Darwin.listen(fd, backlog) < 0 {
        let e = errno
        Darwin.close(fd)
        throw SocketError.listen(e)
    }

    // chmod 0600 so only the user can connect.
    chmod(path, 0o600)

    return UnixSocket(fd: fd)
}

func acceptConnection(on listener: UnixSocket) throws -> UnixSocket {
    let conn = Darwin.accept(listener.fd, nil, nil)
    if conn < 0 {
        throw SocketError.accept(errno)
    }
    return UnixSocket(fd: conn)
}
