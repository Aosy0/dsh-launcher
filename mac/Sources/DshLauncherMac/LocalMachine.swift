import Darwin
import Foundation

/// Local dsh lifecycle through a per-machine LaunchAgent.
///
/// Why launchd instead of a child process (the Windows launcher uses Task Scheduler
/// + wscript for the same reason): the dsh server must detach from the caller's
/// process tree so `dshl start` does not wait for it and the server survives the
/// launcher (and the SSH session) closing.
enum LocalMachine {
    static func commandLine(_ machine: Machine) -> String {
        "dsh \(machine.profile) --port \(machine.port) --no-open"
    }

    static func logPath(_ machine: Machine) -> String {
        Paths.logPath(machine.id)
    }

    static func scriptPath(_ machine: Machine) -> String {
        Paths.runScriptPath(machine.id)
    }

    static func label(_ machine: Machine) -> String {
        Paths.label(machine.id)
    }

    // MARK: Status

    static func status(_ machine: Machine) async -> MachineStatus {
        var status = MachineStatus(
            port: machine.port,
            url: machine.targetURLString,
            platform: "macOS",
            command: commandLine(machine)
        )
        guard let pid = Ports.listenerPID(machine.port) else {
            status.state = .stopped
            status.portOpen = false
            return status
        }
        status.state = .running
        status.portOpen = true
        status.pid = pid
        let facts = ProcessInfoReader.uptimeAndMemory(pid: pid)
        status.uptimeSeconds = facts.seconds
        status.memoryMb = facts.memoryMb
        status.httpStatus = await Ports.httpStatus(port: machine.port)
        return status
    }

    // MARK: Start

    static func start(
        _ machine: Machine,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async -> (Bool, String) {
        if let existing = Ports.listenerPID(machine.port) {
            return (true, "already running (PID \(existing))")
        }
        guard let install = DshResolver.find() else {
            return (false, "dsh が見つかりません（npm i -g @deepseek-ai/dsh で導入してください）")
        }
        do {
            try Paths.ensureDirs()
        } catch {
            return (false, "設定フォルダを作成できません: \(error.localizedDescription)")
        }

        let logFile = logPath(machine)
        do {
            try writeStartScript(machine, install: install, logFile: logFile)
            try writeLaunchAgent(machine, install: install, logFile: logFile)
        } catch {
            return (false, "起動スクリプトを書き込めません: \(error.localizedDescription)")
        }

        let label = label(machine)
        let uid = getuid()
        _ = await Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"], timeout: 10)
        onProgress?("launchctl bootstrap")
        var boot = await Shell.run(
            "/bin/launchctl",
            ["bootstrap", "gui/\(uid)", Paths.plistPath(machine.id)],
            timeout: 20
        )
        if !boot.ok {
            // A previous instance may still be registered; retry once after a short wait.
            try? await Task.sleep(nanoseconds: 500_000_000)
            _ = await Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"], timeout: 10)
            boot = await Shell.run(
                "/bin/launchctl",
                ["bootstrap", "gui/\(uid)", Paths.plistPath(machine.id)],
                timeout: 20
            )
        }
        if !boot.ok {
            let detail = boot.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = tail(machine, lines: 8).joined(separator: "\n")
            return (false, "launchctl bootstrap に失敗しました: \(detail)\(tail.isEmpty ? "" : "\n" + tail)")
        }

        // RunAtLoad is false so an installed LaunchAgent does not start dsh at
        // login by itself; `start` is always an explicit kickstart.
        let kick = await Shell.run(
            "/bin/launchctl",
            ["kickstart", "-k", "gui/\(uid)/\(label)"],
            timeout: 15
        )
        if !kick.ok {
            let detail = kick.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = tail(machine, lines: 8).joined(separator: "\n")
            return (false, "launchctl kickstart に失敗しました: \(detail)\(tail.isEmpty ? "" : "\n" + tail)")
        }

        onProgress?("ポート \(machine.port) を待っています")
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: logFile
        )
        if await Ports.waitUntilListening(machine.port, timeout: 60) {
            let pid = Ports.listenerPID(machine.port).map { "PID \($0)" } ?? "port \(machine.port)"
            return (true, "started (\(pid))")
        }
        let tail = tail(machine, lines: 12).joined(separator: "\n")
        return (false, "起動を待ちましたがポート \(machine.port) が開きません\(tail.isEmpty ? "" : "\n" + tail)")
    }

    // MARK: Stop

    static func stop(_ machine: Machine) async -> (Bool, String) {
        let uid = getuid()
        let label = label(machine)
        _ = await Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"], timeout: 15)

        if let pid = Ports.listenerPID(machine.port) {
            terminateTree(pid: pid)
            if !(await Ports.waitUntilClosed(machine.port, timeout: 10)) {
                killTree(pid: pid)
                if !(await Ports.waitUntilClosed(machine.port, timeout: 5)) {
                    return (false, "ポート \(machine.port) がまだ使用中です（PID \(pid)）")
                }
            }
        }

        try? FileManager.default.removeItem(atPath: Paths.plistPath(machine.id))
        return (true, "stopped")
    }

    static func restart(
        _ machine: Machine,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async -> (Bool, String) {
        let stopped = await stop(machine)
        guard stopped.0 else { return stopped }
        return await start(machine, onProgress: onProgress)
    }

    // MARK: Logs

    static func tail(_ machine: Machine, lines: Int) -> [String] {
        readTail(path: logPath(machine), lines: lines)
    }

    static func readTail(path: String, lines: Int) -> [String] {
        guard lines > 0 else { return [] }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return []
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        let start = size > window ? size - window : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        guard !data.isEmpty else { return [] }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        var result = text
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
        while result.last?.isEmpty == true { result.removeLast() }
        if result.count > lines {
            result = Array(result.suffix(lines))
        }
        return result
    }

    // MARK: Files

    private static func writeStartScript(
        _ machine: Machine,
        install: DshInstall,
        logFile: String
    ) throws {
        let quote: (String) -> String = { value in
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let pathEntries = install.pathEntries + [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ]
        var lines: [String] = [
            "#!/bin/sh",
            "# Generated by DSH Launcher. Safe to delete; regenerate with `dshl start`.",
            "export HOME=\(quote(Paths.home.path))",
            "export PATH=\(quote(pathEntries.joined(separator: ":")))"
        ]
        for key in machine.environment.keys.sorted() {
            lines.append("export \(key)=\(quote(machine.environment[key] ?? ""))")
        }
        lines.append("cd \"$HOME\" || exit 1")
        let argv = install.command + [machine.profile, "--port", String(machine.port), "--no-open"]
        lines.append("exec " + argv.map(quote).joined(separator: " "))
        let content = lines.joined(separator: "\n") + "\n"
        let path = scriptPath(machine)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        _ = logFile
    }

    private static func writeLaunchAgent(
        _ machine: Machine,
        install: DshInstall,
        logFile: String
    ) throws {
        try FileManager.default.createDirectory(
            atPath: Paths.launchAgentsDir.path,
            withIntermediateDirectories: true
        )
        var environment: [String: String] = [
            "HOME": Paths.home.path,
            "PATH": ([Paths.home.path + "/.npm-global/bin"] + install.pathEntries + [
                "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"
            ]).joined(separator: ":")
        ]
        for (key, value) in machine.environment {
            environment[key] = value
        }
        let plist: [String: Any] = [
            "Label": label(machine),
            "ProgramArguments": ["/bin/sh", scriptPath(machine)],
            "RunAtLoad": false,
            "KeepAlive": false,
            "ProcessType": "Background",
            "Umask": 63, // 0o77: StandardOutPath is created 0600 (the log holds the token URL).
            "ThrottleInterval": 10,
            "WorkingDirectory": Paths.home.path,
            "StandardOutPath": logFile,
            "StandardErrorPath": logFile,
            "EnvironmentVariables": environment
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: URL(fileURLWithPath: Paths.plistPath(machine.id)), options: .atomic)
    }

    // MARK: Process tree

    private static func childPIDs(of pid: Int32) -> [Int32] {
        let result = Shell.runSync(
            executable: "/usr/bin/pgrep",
            arguments: ["-P", String(pid)],
            timeout: 4
        )
        return result.stdout
            .components(separatedBy: .newlines)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func allDescendants(of pid: Int32) -> [Int32] {
        var result: [Int32] = []
        for child in childPIDs(of: pid) {
            result.append(child)
            result.append(contentsOf: allDescendants(of: child))
        }
        return result
    }

    private static func terminateTree(pid: Int) {
        let root = Int32(pid)
        for child in allDescendants(of: root).reversed() {
            kill(child, SIGTERM)
        }
        kill(root, SIGTERM)
    }

    private static func killTree(pid: Int) {
        let root = Int32(pid)
        for child in allDescendants(of: root).reversed() {
            kill(child, SIGKILL)
        }
        kill(root, SIGKILL)
    }
}
