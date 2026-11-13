import Foundation

/// Small append-only log for the app itself. The dsh server log is separate
/// (logs/<machine>.log); this file records launcher lifecycle and errors so the
/// GUI can be diagnosed over SSH or from a support report.
enum Log {
    private static let lock = NSLock()

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try Paths.ensureDirs()
            let path = Paths.logsDir.appendingPathComponent("app.log").path
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let line = "\(formatter.string(from: Date())) \(message)\n"
            let fm = FileManager.default
            if !fm.fileExists(atPath: path) {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                return
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            // Logging must never take the app down.
        }
    }
}
