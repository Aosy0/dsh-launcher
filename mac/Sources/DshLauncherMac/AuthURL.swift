import Foundation

/// Issues the `?token=` URL that authenticates a *new* browser against the local DSH.
///
/// dsh web mints a random launch token per process and prints it once at startup as
/// `dsh web: <url>?token=...`. The token is never persisted, so the startup line in the
/// launch log is the only source. The log keeps accepting appends while dsh runs, so only
/// its tail is examined.
///
/// Lines from earlier runs remain in the file, so a candidate is accepted only after the
/// running server answers its token with a redirect that mints the `dsh-auth-` cookie: a
/// stale token gets 401, and a cookie-bearing client would get a redirect without a fresh
/// cookie. The token does not depend on the authority, so the same value can be offered on
/// the loopback URL (this Mac) and on the configured public URL (another device).
enum AuthURL {
    /// Tail window large enough to hold several runs' startup lines.
    private static let maxLogBytes: UInt64 = 256 * 1024
    private static let maxCandidates = 6
    /// dsh prints its URL a few seconds after the socket starts listening, and `dshl start`
    /// returns as soon as the port is open, so an `auth-url` issued right after a start can
    /// arrive before the new line is in the log. Keep looking for a while instead of trusting
    /// the previous run's token (which answers 401).
    private static let startupGrace: TimeInterval = 10
    private static let retryNanoseconds: UInt64 = 300_000_000
    private static let probeTimeout: TimeInterval = 4

    /// `dsh web: http://127.0.0.1:3080/?token=...`
    private static let startupLine = try? NSRegularExpression(
        pattern: "dsh web:\\s*(https?://\\S+)"
    )

    // MARK: - Issue

    /// Issues the URL for a running local DSH, or explains why it cannot.
    static func issue(for machine: Machine) async -> AuthURLResult {
        guard machine.kind == .local else {
            return failure("認証 URL はこの PC の DSH で発行できます（リモートは未対応です）。")
        }

        guard let pid = Ports.listenerPID(machine.port) else {
            return failure("DSH が停止しています。起動してから発行してください。")
        }

        let deadline = Date().addingTimeInterval(startupGrace)
        var sawStartupLine = false
        var sawToken = false
        // Verdict on the newest log line only: older lines always belong to earlier runs, so
        // their 401 says nothing about whether the running process's line has been written yet.
        var newestRejected = false

        while true {
            for (index, printed) in candidates(machine).enumerated() {
                sawStartupLine = true
                if Date() >= deadline { break }
                guard let token = token(of: printed) else { continue }
                sawToken = true
                let verdict = await probe(port: machine.port, token: token)
                switch verdict {
                case .accepted:
                    return build(machine: machine, printed: printed, token: token, pid: pid)
                case .rejected:
                    if index == 0 { newestRejected = true }
                case .unreachable:
                    // A newer line exists but could not be verified yet: keep waiting for it
                    // instead of blaming the previous run's token.
                    if index == 0 { newestRejected = false }
                }
            }

            if Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: retryNanoseconds)
            if Task.isCancelled { break }
        }

        if newestRejected {
            return failure("起動時の認証 URL は古くなっています。ランチャーから再起動すると新しい URL を発行できます。")
        }
        if sawToken {
            return failure(
                "認証 URL を検証できませんでした。ポート \(machine.port) の応答を待ちましたが"
                    + "タイムアウトしました（起動直後の場合は少し待ってから発行してください）。"
            )
        }
        if sawStartupLine {
            return failure(
                "認証 URL を取得できませんでした。起動ログの `dsh web:` 行に token がありません"
                    + "（printUrl: false の構成では発行できません）。"
            )
        }
        return failure(
            "認証 URL を取得できませんでした。起動ログに `dsh web: …?token=…` がありません"
                + "（ランチャー経由で起動すると取得できます）。"
        )
    }

    // MARK: - Log candidates

    /// Startup URLs in the log, newest first and de-duplicated.
    private static func candidates(_ machine: Machine) -> [URL] {
        guard let regex = startupLine else { return [] }
        let lines = readLogLines(Paths.logPath(machine.id))

        var urls: [URL] = []
        var seen = Set<String>()
        for line in lines.reversed() where urls.count < maxCandidates {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, options: [], range: range),
                  let captured = Range(match.range(at: 1), in: line) else { continue }
            let raw = String(line[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw), isWeb(url) else { continue }
            if !seen.insert(url.absoluteString).inserted { continue }
            urls.append(url)
        }
        return urls
    }

    /// Reads the last 256 KB of the log. The first line of a windowed read starts mid-line.
    private static func readLogLines(_ path: String) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > maxLogBytes ? size - maxLogBytes : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        guard !data.isEmpty else { return [] }

        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
    }

    private static func token(of url: URL) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        for item in items where item.name == "token" {
            if let value = item.value, !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - Probe

    private enum ProbeResult {
        /// The server answered with a redirect that mints the browser-session cookie.
        case accepted
        /// The server answered 401: the token belongs to an earlier run.
        case rejected
        /// No usable answer (stopped, starting, or another service on the port).
        case unreachable
    }

    /// Verifies a token against the running server.
    ///
    /// The probe always targets the loopback listener (the log URL may name a public host)
    /// and never keeps cookies or follows redirects: a stored session cookie would make a
    /// stale token look valid, because the server also redirects a request that already
    /// carries one. A 200 is rejected as well for the same reason.
    private static func probe(port: Int, token: String) async -> ProbeResult {
        guard let probeURL = withToken("http://127.0.0.1:\(port)/", token: token)
            .flatMap({ URL(string: $0) }) else {
            return .unreachable
        }

        var request = URLRequest(url: probeURL)
        request.httpMethod = "GET"
        request.setValue("DSHLauncher/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, response) = try await probeSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            if http.statusCode == 401 { return .rejected }
            guard (300..<400).contains(http.statusCode) else { return .unreachable }
            return mintsSession(http) ? .accepted : .unreachable
        } catch {
            return .unreachable
        }
    }

    /// True when the response carries a `Set-Cookie: dsh-auth-…` header.
    private static func mintsSession(_ response: HTTPURLResponse) -> Bool {
        for (key, value) in response.allHeaderFields {
            guard String(describing: key).caseInsensitiveCompare("Set-Cookie") == .orderedSame else {
                continue
            }
            if String(describing: value).lowercased().contains("dsh-auth-") { return true }
        }
        return false
    }

    /// The probe must reach the local listener directly (a system proxy would not see it)
    /// and must surface redirects instead of following them.
    private static let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = probeTimeout
        configuration.timeoutIntervalForResource = probeTimeout + 2
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: NoRedirectProbe(), delegateQueue: nil)
    }()

    private final class NoRedirectProbe: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            // nil = do not follow: the 3xx itself is what proves the token was accepted.
            completionHandler(nil)
        }
    }

    // MARK: - Result

    private static func build(
        machine: Machine,
        printed: URL,
        token: String,
        pid: Int
    ) -> AuthURLResult {
        let loopback = "http://127.0.0.1:\(machine.port)/"
        let localURL = withToken(loopback, token: token) ?? loopback

        var externalBase: String?
        if let configured = machine.url?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty,
           let url = URL(string: configured),
           isWeb(url) {
            externalBase = configured
        }
        if externalBase == nil, isWeb(printed), !isLoopback(printed) {
            externalBase = printed.absoluteString
        }

        let externalURL = externalBase.flatMap { withToken($0, token: token) }
        return AuthURLResult(
            ok: true,
            url: externalURL ?? localURL,
            localUrl: localURL,
            externalUrl: externalURL,
            pid: pid,
            message: ""
        )
    }

    private static func failure(_ message: String) -> AuthURLResult {
        AuthURLResult(
            ok: false,
            url: nil,
            localUrl: nil,
            externalUrl: nil,
            pid: nil,
            message: message
        )
    }

    // MARK: - Helpers

    /// Replaces the token parameter while keeping the rest of the address.
    private static func withToken(_ base: String, token: String) -> String? {
        guard var components = URLComponents(string: base) else { return nil }

        var pairs = (components.percentEncodedQuery ?? "")
            .split(separator: "&", omittingEmptySubsequences: true)
            .map { String($0) }
            .filter { pair in
                let name = pair.split(separator: "=", maxSplits: 1).first.map { String($0) } ?? ""
                return name != "token" && name.removingPercentEncoding != "token"
            }
        pairs.append("token=" + percentEncoded(token))
        components.percentEncodedQuery = pairs.joined(separator: "&")
        return components.url?.absoluteString
    }

    /// Percent-encodes every character that is not unreserved, so `+` reaches the server as
    /// `%2B` instead of being read as a space.
    private static func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return !(url.host ?? "").isEmpty
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        return host.hasPrefix("127.")
    }
}
