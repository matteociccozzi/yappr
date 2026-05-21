import Foundation

enum Log {
    static func info(_ msg: String) {
        write("INFO ", msg)
    }

    static func warn(_ msg: String) {
        write("WARN ", msg)
    }

    static func error(_ msg: String) {
        write("ERROR", msg)
    }

    private static func write(_ level: String, _ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) [\(level)] \(msg)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
