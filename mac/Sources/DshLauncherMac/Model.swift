import Foundation

// MARK: - App metadata

enum AppInfo {
    static let name = "DSH Launcher"
    static let bundleIdentifier = "io.github.aosy0.dshlauncher"
    static let version = "0.1.0"
    /// LaunchAgent label prefix. The full label is `<prefix><sanitized machine id>`.
    static let launchLabelPrefix = "io.github.aosy0.dshlauncher.start-"
}

// MARK: - Machine model

enum MachineKind: String, Codable, Sendable {
    case local = "Local"
    case ssh = "Ssh"
}

enum MachineState: String, Codable, Sendable {
    case unknown
    case running
    case starting
    case stopped
    case needsSetup
    case unreachable

    var text: String {
        switch self {
        case .unknown: return "不明"
        case .running: return "稼働中"
        case .starting: return "起動中"
        case .stopped: return "停止"
        case .needsSetup: return "要セットアップ"
        case .unreachable: return "到達不可"
        }
    }
}

struct Machine: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var kind: MachineKind
    var name: String
    var sshAlias: String?
    var platform: String
    var profile: String
    var port: Int
    var url: String?
    var pinned: Bool
    var environment: [String: String]

    init(
        id: String,
        kind: MachineKind,
        name: String,
        sshAlias: String? = nil,
        platform: String = "auto",
        profile: String = "web",
        port: Int = 3080,
        url: String? = nil,
        pinned: Bool = true,
        environment: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.sshAlias = sshAlias
        self.platform = platform
        self.profile = profile
        self.port = port
        self.url = url
        self.pinned = pinned
        self.environment = environment
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, sshAlias, platform, profile, port, url, pinned, environment
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        let kindText = try c.decodeIfPresent(String.self, forKey: .kind) ?? "Local"
        kind = MachineKind(rawValue: kindText) ?? .local
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        sshAlias = try c.decodeIfPresent(String.self, forKey: .sshAlias)
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? "auto"
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? "web"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 3080
        url = try c.decodeIfPresent(String.self, forKey: .url)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? true
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
    }

    var displayName: String {
        kind == .local ? "\(name)(local)" : name
    }

    var targetURLString: String {
        if let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return url
        }
        return "http://127.0.0.1:\(port)/"
    }

    var targetURL: URL? {
        URL(string: targetURLString)
    }

    var isLocal: Bool { kind == .local }

    /// The SSH destination used for probing and actions.
    var sshDestination: String {
        sshAlias ?? id
    }
}

struct LauncherConfig: Codable, Sendable {
    var version: Int
    var machines: [Machine]

    init(version: Int = 1, machines: [Machine] = []) {
        self.version = version
        self.machines = machines
    }

    private enum CodingKeys: String, CodingKey {
        case version, machines
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        machines = try c.decodeIfPresent([Machine].self, forKey: .machines) ?? []
    }

    static func load(path: String? = nil) -> LauncherConfig {
        let file = path.map { URL(fileURLWithPath: $0) } ?? Paths.configPath
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                let decoded = try JSONDecoder().decode(LauncherConfig.self, from: data)
                if !decoded.machines.isEmpty {
                    return decoded
                }
            }
        } catch {
            // A broken config falls back to defaults; the UI can save over it.
        }
        let created = makeDefault()
        try? created.save(path: path)
        return created
    }

    func save(path: String? = nil) throws {
        let file = path.map { URL(fileURLWithPath: $0) } ?? Paths.configPath
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        try data.write(to: file, options: .atomic)
    }

    static func makeDefault() -> LauncherConfig {
        var machines: [Machine] = [
            Machine(id: "local", kind: .local, name: HostInfo.computerName)
        ]
        var seen = Set<String>(["local"])
        for alias in SshConfig.aliases() where !seen.contains(alias.lowercased()) {
            seen.insert(alias.lowercased())
            machines.append(
                Machine(id: alias, kind: .ssh, name: alias, sshAlias: alias)
            )
        }
        return LauncherConfig(version: 1, machines: machines)
    }

    func find(_ idOrName: String) -> Machine? {
        machines.first { machine in
            machine.id.caseInsensitiveCompare(idOrName) == .orderedSame
                || machine.name.caseInsensitiveCompare(idOrName) == .orderedSame
                || machine.displayName.caseInsensitiveCompare(idOrName) == .orderedSame
        }
    }

    var localMachine: Machine? {
        machines.first { $0.kind == .local } ?? machines.first
    }
}

// MARK: - Status

struct MachineStatus: Codable, Sendable {
    var state: MachineState = .unknown
    var pid: Int?
    var port: Int?
    var uptimeSeconds: Double?
    var memoryMb: Int?
    var url: String?
    var platform: String?
    var nodeVersion: String?
    var dshInstalled: Bool?
    var dshHome: Bool?
    var portOpen: Bool?
    var note: String?
    var error: String?
    var latencyMs: Int?
    var command: String?
    var httpStatus: Int?

    var stateText: String { state.text }

    var uptimeText: String? {
        guard let seconds = uptimeSeconds, seconds > 0 else { return nil }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    var memoryText: String? {
        guard let memoryMb else { return nil }
        return "\(memoryMb) MB"
    }
}

// MARK: - Shared UI / service value types

enum ActionKind: String, Sendable, CaseIterable {
    case start
    case stop
    case restart

    var title: String {
        switch self {
        case .start: return "起動"
        case .stop: return "停止"
        case .restart: return "再起動"
        }
    }

    var busyLabel: String {
        switch self {
        case .start: return "起動中"
        case .stop: return "停止中"
        case .restart: return "再起動中"
        }
    }
}

struct ConfirmRequest: Identifiable, Sendable {
    let id = UUID()
    var machine: Machine
    var action: ActionKind
    var command: String
    var currentState: String
    var note: String?
}

struct BusyState: Sendable, Equatable {
    var label: String
    var startedAt: Date

    var elapsedText: String {
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        return "\(seconds)s"
    }
}

struct LogViewState: Identifiable, Sendable {
    let id = UUID()
    var title: String
    var lines: [String]
    var loading: Bool
    var message: String?
}

struct AuthURLResult: Sendable {
    var ok: Bool
    var url: String?
    var localUrl: String?
    var externalUrl: String?
    var pid: Int?
    var message: String
}

struct PwaInfo: Sendable {
    var installed: Bool
    var url: String
    var appId: String?
    var appPath: String?
    var bundleId: String?
    var browser: String?
    var appName: String?
    var message: String?
    var browsers: [BrowserInfo] = []
}

struct BrowserInfo: Sendable {
    var name: String
    var bundleId: String?
    var appPath: String?
    var pwaDirs: [String]
}

struct SetupStep: Sendable, Hashable, Codable {
    var name: String
    var state: String
    var detail: String
}

struct SetupOutcome: Sendable {
    var ok: Bool
    var message: String
    var steps: [SetupStep]
    var transcript: [String]
}

// MARK: - Paths

enum Paths {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static var supportDir: URL {
        home.appendingPathComponent("Library/Application Support/DshLauncher", isDirectory: true)
    }

    static var configPath: URL {
        supportDir.appendingPathComponent("hosts.json")
    }

    static var logsDir: URL {
        supportDir.appendingPathComponent("logs", isDirectory: true)
    }

    static var runDir: URL {
        supportDir.appendingPathComponent("run", isDirectory: true)
    }

    static var launchAgentsDir: URL {
        home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    static var tempDir: URL {
        FileManager.default.temporaryDirectory
    }

    static func sanitize(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let value = String(scalars)
        return value.isEmpty ? "machine" : value
    }

    static func label(_ machineId: String) -> String {
        AppInfo.launchLabelPrefix + sanitize(machineId)
    }

    static func plistPath(_ machineId: String) -> String {
        launchAgentsDir.appendingPathComponent(label(machineId) + ".plist").path
    }

    static func runScriptPath(_ machineId: String) -> String {
        runDir.appendingPathComponent(sanitize(machineId) + ".sh").path
    }

    static func logPath(_ machineId: String) -> String {
        logsDir.appendingPathComponent(sanitize(machineId) + ".log").path
    }

    static func ensureDirs() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: runDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        // The dsh start log contains the one-time ?token= URL: keep the app's own
        // directories readable only by this user.
        for directory in [supportDir, logsDir, runDir] {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }
}

// MARK: - Host info

enum HostInfo {
    static var computerName: String {
        let name = Shell.runSync(
            executable: "/usr/sbin/scutil",
            arguments: ["--get", "ComputerName"],
            timeout: 3
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            return name
        }
        return ProcessInfo.processInfo.hostName
    }
}

// MARK: - SSH config aliases

enum SshConfig {
    /// Host aliases from ~/.ssh/config, matching the Windows launcher's rules:
    /// first name only, skip wildcards and github.com.
    static func aliases() -> [String] {
        let path = Paths.home.appendingPathComponent(".ssh/config").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        var result: [String] = []
        var seen = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("host ") else { continue }
            let rest = line.dropFirst(5)
            guard let first = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
                continue
            }
            let name = String(first)
            if name.contains("*") || name.contains("?") { continue }
            if name.caseInsensitiveCompare("github.com") == .orderedSame { continue }
            if seen.contains(name.lowercased()) { continue }
            seen.insert(name.lowercased())
            result.append(name)
        }
        return result
    }
}

// MARK: - JSON helpers

enum JsonTool {
    static func encode<T: Encodable>(_ value: T, pretty: Bool = true) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .withoutEscapingSlashes]
            : [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
