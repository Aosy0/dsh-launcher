import Foundation

/// Local TCP probing helpers. Ports are the source of truth for "is dsh listening".
enum Ports {
    static func listenerPID(_ port: Int) -> Int? {
        let result = Shell.runSync(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"],
            timeout: 5
        )
        let pids = result.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { Int($0) }
            .filter { $0 > 0 }
        return pids.first
    }

    static func httpStatus(port: Int, timeout: TimeInterval = 1.5) async -> Int? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.httpMethod = "GET"
        request.setValue("DSHLauncher/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        } catch {
            return nil
        }
    }

    static func isListening(_ port: Int) async -> Bool {
        await httpStatus(port: port) != nil
    }

    static func waitUntilListening(_ port: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if listenerPID(port) != nil { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return listenerPID(port) != nil
    }

    static func waitUntilClosed(_ port: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if listenerPID(port) == nil { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return listenerPID(port) == nil
    }
}

/// Facts about a listening process for the compact status line.
enum ProcessInfoReader {
    static func uptimeAndMemory(pid: Int) -> (seconds: Double?, memoryMb: Int?) {
        let result = Shell.runSync(
            executable: "/bin/ps",
            arguments: ["-o", "etime=", "-o", "rss=", "-p", String(pid)],
            timeout: 5
        )
        let parts = result.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard parts.count >= 2 else { return (nil, nil) }
        let seconds = parseElapsed(parts[0])
        let memoryKb = Int(parts[1])
        return (seconds, memoryKb.map { $0 / 1024 })
    }

    /// `ps` etime: `[[dd-]hh:]mm:ss`.
    static func parseElapsed(_ text: String) -> Double? {
        var value = text
        var days = 0.0
        if let dash = value.firstIndex(of: "-") {
            days = Double(value[value.startIndex..<dash]) ?? 0
            value = String(value[value.index(after: dash)...])
        }
        let fields = value.split(separator: ":").map { Double($0) ?? 0 }
        switch fields.count {
        case 3:
            return days * 86400 + fields[0] * 3600 + fields[1] * 60 + fields[2]
        case 2:
            return days * 86400 + fields[0] * 60 + fields[1]
        case 1:
            return days * 86400 + fields[0]
        default:
            return nil
        }
    }
}
