import Foundation

/// One SSH invocation's result.
struct SshResult: Sendable {
    var exit: Int32
    var stdout: String
    var stderr: String

    var stdoutTrimmed: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    var stderrTrimmed: String { stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// SSH transport for remote machines.
///
/// macOS ships `/usr/bin/ssh`, and the launcher only ever uses `~/.ssh/config` aliases
/// plus the user's keys/agent: `BatchMode=yes` guarantees ssh never prompts for a
/// password (there is nobody to answer in a GUI app, and a prompt would just hang).
enum SshTransport {
    static let executable = "/usr/bin/ssh"

    /// Argument vector shared by every call. A new host key is accepted on first use
    /// (TOFU, same as the Windows launcher) and the connect timeout stays short so the
    /// periodic status refresh cannot stall on an unreachable host.
    static func arguments(alias: String, command: String) -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=accept-new",
            alias,
            command,
        ]
    }

    static func run(
        alias: String,
        command: String,
        timeout: TimeInterval,
        stdin: String? = nil
    ) async -> SshResult {
        let result = await Shell.run(
            SshTransport.executable,
            arguments(alias: alias, command: command),
            timeout: timeout,
            stdin: stdin
        )
        return completed(result, timeout: timeout)
    }

    /// Run a PowerShell script on a Windows host. The script travels as base64 of
    /// UTF-16LE (`-EncodedCommand`), so nothing has to survive cmd.exe quoting.
    static func runPowerShell(
        alias: String,
        script: String,
        timeout: TimeInterval
    ) async -> SshResult {
        let encoded = ScriptEncoding.encodedCommand(script)
        return await run(
            alias: alias,
            command: "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand \(encoded)",
            timeout: timeout
        )
    }

    /// Convert the shell result. A timeout keeps whatever output arrived (useful for the
    /// setup transcript) and reports itself with the Windows launcher's wording.
    private static func completed(_ result: ShellResult, timeout: TimeInterval) -> SshResult {
        guard result.timedOut else {
            return SshResult(exit: result.exit, stdout: result.stdout, stderr: result.stderr)
        }
        var stderr = result.stderr
        if !stderr.isEmpty { stderr += "\n" }
        stderr += "timeout after \(Int(timeout))s"
        return SshResult(exit: -2, stdout: result.stdout, stderr: stderr)
    }
}

/// Timeouts, mirroring the Windows launcher's `Remote.cs` / `Setup.cs`.
enum RemoteTimeouts {
    /// Status probe.
    static let probe: TimeInterval = 15
    /// start/stop/restart; the helper itself waits up to 90 s for the port.
    static let action: TimeInterval = 120
    /// Helper or setup-script deployment over SSH.
    static let deploy: TimeInterval = 30
    /// Full setup (nvm/portable Node download plus `npm install`).
    static let setup: TimeInterval = 900
    /// Reading the remote log.
    static let logs: TimeInterval = 20
    /// Windows PowerShell probe.
    static let windowsProbe: TimeInterval = 20
}

/// The helper protocol is line-oriented JSON, so parsing stays deliberately small.
enum RemoteJSON {
    static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The last line that looks like a JSON object: helpers print progress first and the
    /// final state last (`agent.sh status`, `agent.ps1 -Verb ...`).
    static func lastObject(in text: String) -> [String: Any]? {
        let objects = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("{") }
        guard let last = objects.last else { return nil }
        return object(last)
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
}

/// Remote machine status and control through SSH plus the small helper scripts.
///
/// The behaviour matches the Windows launcher (Remote.cs) unless a comment says
/// otherwise; the visible differences are about macOS: `/usr/bin/ssh` instead of
/// `ssh`, no per-machine console, and an `agent.sh` that survives a missing `setsid`.
enum RemoteMachine {
    // MARK: - Commands

    /// Short status probe shown to the user. Identical to the Windows launcher's display
    /// string; the probe that actually runs also prepends the node/npm PATH, checks the
    /// port and asks the helper for its JSON state.
    static func statusCommand(_ machine: Machine) -> String {
        "ssh \(machine.sshDestination) 'uname -s; node -v; command -v dsh; ls ~/.dsh'"
    }

    /// The command `action(_:_:)` runs. The Windows launcher shows a shorter form, but
    /// printing what really runs is more useful in the confirm dialog and `--dry-run`.
    static func actionCommand(_ machine: Machine, _ verb: String) -> String {
        let alias = machine.sshDestination
        if machine.platform == "windows" {
            return "ssh \(alias) 'powershell -NoProfile -File ~/.dsh/dshl/agent.ps1"
                + " -Verb \(verb) -Port \(machine.port) -ProfileName \(machine.profile)'"
        }
        return "ssh \(alias) 'DSH_PORT=\(machine.port) DSH_PROFILE=\(machine.profile)"
            + " sh ~/.dsh/dshl/agent.sh \(verb)'"
    }

    // MARK: - Status

    static func status(_ machine: Machine) async -> MachineStatus {
        let alias = machine.sshDestination
        var status = MachineStatus(
            port: machine.port,
            url: machine.targetURLString,
            command: statusCommand(machine)
        )
        let started = Date()

        // Like the Windows launcher, a POSIX probe runs first even for a configured
        // Windows host: cmd.exe simply fails it and the PowerShell probe answers.
        let result = await SshTransport.run(
            alias: alias,
            command: posixProbe(machine),
            timeout: RemoteTimeouts.probe
        )
        status.latencyMs = Int((Date().timeIntervalSince(started) * 1000).rounded())

        if result.stdout.contains("Linux") {
            status.platform = "Linux"
            applyPosixProbe(&status, stdout: result.stdout)
        } else if result.stdout.contains("Darwin") {
            status.platform = "macOS"
            applyPosixProbe(&status, stdout: result.stdout)
        } else {
            guard let windows = await probeWindows(machine) else {
                status.state = .unreachable
                status.error = result.stderrTrimmed.isEmpty ? "ssh probe failed" : result.stderrTrimmed
                return status
            }
            status.platform = "Windows"
            applyWindowsProbe(&status, stdout: windows)
        }

        if status.dshInstalled != true || !isNodeSupported(status.nodeVersion) {
            status.state = .needsSetup
            status.note = status.dshInstalled != true
                ? "dsh が見つかりません"
                : "Node \(status.nodeVersion ?? "") は 24.9 以上が必要です"
            return status
        }

        status.state = status.portOpen == true ? .running : .stopped
        return status
    }

    /// One SSH round trip gathering everything the status line needs: PATH-managed
    /// node/dsh, the `~/.dsh` home, the port listener, and the helper's JSON state.
    ///
    /// The PATH list follows the Windows launcher and adds Homebrew's directories: a
    /// non-interactive SSH session on macOS does not get them from the login shell, and
    /// that is exactly where a Homebrew node/dsh lives. nvm versions are added newest
    /// first with `find` rather than a `for ... in ~/.nvm/versions/node/*/bin` loop: on
    /// macOS the login shell over SSH is zsh, whose default `nomatch` turns an unmatched
    /// glob into an error for that command.
    private static func posixProbe(_ machine: Machine) -> String {
        let statements = [
            "PATH=\"$HOME/.dsh/npm-global/bin:$HOME/.dsh/runtime/node/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"",
            "PATH=\"$(find \"$HOME/.nvm/versions/node\" -mindepth 2 -maxdepth 2 -type d -name bin 2>/dev/null | sort -r | tr '\\n' ':')$PATH\"",
            "export PATH",
            "uname -s 2>/dev/null",
            "node -v 2>/dev/null",
            "command -v dsh 2>/dev/null || echo NO_DSH",
            "[ -d \"$HOME/.dsh\" ] && echo DSH_HOME || echo NO_DSH_HOME",
            portOpenFunction(port: machine.port),
            "port_open && echo PORT_OPEN || echo PORT_CLOSED",
            "if [ -f \"$HOME/.dsh/dshl/agent.sh\" ]; then sh \"$HOME/.dsh/dshl/agent.sh\" status 2>/dev/null; fi",
        ]
        return statements.joined(separator: "; ")
    }

    /// `ss` exists on Linux, `netstat -ltn` exists on both (macOS prints `address.port`
    /// with a dot instead of a colon) and `lsof` is the last resort. Matching `[:.]PORT `
    /// keeps port 13080 from matching a probe of 3080.
    private static func portOpenFunction(port: Int) -> String {
        let pattern = "[:.]\(port) "
        return "port_open() { "
            + "if command -v ss >/dev/null 2>&1; then ss -ltn 2>/dev/null | grep -q \"\(pattern)\"; "
            + "elif command -v netstat >/dev/null 2>&1; then netstat -ltn 2>/dev/null | grep -q \"\(pattern)\"; "
            + "elif command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP:\(port) -sTCP:LISTEN >/dev/null 2>&1; "
            + "else return 1; fi; }"
    }

    /// Parse the newline-separated facts printed by `posixProbe`. Order mirrors the
    /// Windows launcher: node version first (it is the only line starting with `v`),
    /// then the dsh path or its sentinels, then the port and helper JSON.
    private static func applyPosixProbe(_ status: inout MachineStatus, stdout: String) {
        for raw in stdout.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("v"), line.count > 1,
               line[line.index(after: line.startIndex)].isNumber {
                status.nodeVersion = line
            } else if line.hasPrefix("/") {
                status.dshInstalled = true
            } else if line == "NO_DSH" {
                status.dshInstalled = false
            } else if line == "DSH_HOME" {
                status.dshHome = true
            } else if line == "NO_DSH_HOME" {
                status.dshHome = false
            } else if line == "PORT_OPEN" {
                status.portOpen = true
            } else if line == "PORT_CLOSED" {
                status.portOpen = false
            } else if line.hasPrefix("{"), let json = RemoteJSON.object(line) {
                if RemoteJSON.string(json["state"]) == "running" {
                    status.state = .running
                    if let pid = RemoteJSON.int(json["pid"]) { status.pid = pid }
                }
            }
        }
    }

    private static func probeWindows(_ machine: Machine) async -> String? {
        let statements = [
            "$PSVersionTable.PSVersion.Major",
            "'OS=' + $env:OS",
            "'node=' + (node -v 2>$null)",
            "'dsh=' + ((Get-Command dsh -ErrorAction SilentlyContinue).Source)",
            "'home=' + (Test-Path \"$env:USERPROFILE\\.dsh\")",
            "'port=' + ((Get-NetTCPConnection -LocalPort \(machine.port) -State Listen -ErrorAction SilentlyContinue | Measure-Object).Count)",
        ]
        let result = await SshTransport.runPowerShell(
            alias: machine.sshDestination,
            script: statements.joined(separator: "; "),
            timeout: RemoteTimeouts.windowsProbe
        )
        guard result.exit == 0, result.stdout.contains("OS=") else { return nil }
        return result.stdout
    }

    private static func applyWindowsProbe(_ status: inout MachineStatus, stdout: String) {
        for raw in stdout.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator])
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "node":
                status.nodeVersion = value.isEmpty ? nil : value
            case "dsh":
                status.dshInstalled = !value.isEmpty
            case "home":
                status.dshHome = value.caseInsensitiveCompare("True") == .orderedSame
            case "port":
                status.portOpen = !value.isEmpty && value != "0"
            default:
                break
            }
        }
    }

    /// Node 24.9+ (the version dsh needs). Mirrors `Remote.IsNodeSupported`.
    static func isNodeSupported(_ version: String?) -> Bool {
        guard var text = version?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        while text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let major = Int(parts[0]) else { return false }
        let minor = Int(parts[1]) ?? 0
        return major > 24 || (major == 24 && minor >= 9)
    }

    // MARK: - Deploy

    /// Write the helper onto the remote host. Linux/macOS get `agent.sh` over stdin;
    /// Windows gets `agent.ps1` as base64 with a UTF-8 BOM (PowerShell 5.1 would read
    /// the file as ANSI otherwise). No helper is ever installed without this call.
    static func deploy(_ machine: Machine) async -> (Bool, String) {
        let alias = machine.sshDestination
        if machine.platform == "windows" {
            let script = [
                "$dir = Join-Path $env:USERPROFILE '.dsh\\dshl'",
                "New-Item -ItemType Directory -Force -Path $dir | Out-Null",
                "$bytes = [Convert]::FromBase64String('\(ScriptEncoding.base64UTF8BOM(AgentScripts.windows))')",
                "[IO.File]::WriteAllBytes((Join-Path $dir 'agent.ps1'), $bytes)",
                "'installed ' + (Join-Path $dir 'agent.ps1')",
            ].joined(separator: "\r\n")
            let written = await SshTransport.runPowerShell(
                alias: alias,
                script: script,
                timeout: RemoteTimeouts.deploy
            )
            if written.exit == 0 {
                return (true, written.stdoutTrimmed)
            }
            return (false, written.stderrTrimmed.isEmpty
                ? "failed to write agent.ps1"
                : written.stderrTrimmed)
        }

        let posix = await SshTransport.run(
            alias: alias,
            command: "mkdir -p \"$HOME/.dsh/dshl\" && cat > \"$HOME/.dsh/dshl/agent.sh\""
                + " && chmod 700 \"$HOME/.dsh/dshl/agent.sh\" && echo installed",
            timeout: RemoteTimeouts.deploy,
            stdin: AgentScripts.posix
        )
        if posix.exit == 0 {
            return (true, posix.stdoutTrimmed)
        }
        return (false, posix.stderrTrimmed.isEmpty ? "failed to write agent.sh" : posix.stderrTrimmed)
    }

    // MARK: - Actions

    /// start/stop/restart through the helper. Exit code 4 means the host is not set up
    /// yet; otherwise the last JSON line carries the state or a reason.
    static func action(_ machine: Machine, _ verb: String) async -> (Bool, String) {
        let alias = machine.sshDestination
        let result: SshResult
        if machine.platform == "windows" {
            let script = [
                "$s = Join-Path $env:USERPROFILE '.dsh\\dshl\\agent.ps1'",
                "& $s -Verb \(ScriptEncoding.powerShellQuote(verb))"
                    + " -Port \(machine.port) -ProfileName \(ScriptEncoding.powerShellQuote(machine.profile))",
            ].joined(separator: "; ")
            result = await SshTransport.runPowerShell(
                alias: alias,
                script: script,
                timeout: RemoteTimeouts.action
            )
        } else {
            let command = "DSH_PORT=\(machine.port)"
                + " DSH_PROFILE=\(ScriptEncoding.shellQuote(machine.profile))"
                + " sh \"$HOME/.dsh/dshl/agent.sh\" \(ScriptEncoding.shellQuote(verb))"
            result = await SshTransport.run(
                alias: alias,
                command: command,
                timeout: RemoteTimeouts.action
            )
        }

        if result.exit == 4 { return (false, "needs setup") }
        if let json = RemoteJSON.lastObject(in: result.stdout),
           let state = RemoteJSON.string(json["state"]) {
            if state == "running" || state == "stopped" { return (true, state) }
            // PowerShell does not propagate `exit 4` out of `& script.ps1`, so a Windows
            // host reports "needs setup" through the JSON state instead of the exit code.
            if state == "needs-setup" { return (false, "needs setup") }
            return (false, RemoteJSON.string(json["reason"]) ?? "failed")
        }
        // An empty success is not a useful outcome: treat it as a failure so a missing
        // helper cannot look like a successful start.
        if result.exit == 0, !result.stdoutTrimmed.isEmpty {
            return (true, result.stdoutTrimmed)
        }
        return (false, result.stderrTrimmed.isEmpty ? "remote action failed" : result.stderrTrimmed)
    }

    // MARK: - Logs

    /// Last lines of `~/.dsh/dshl/dsh.log`. Windows hosts fall back to the helper's
    /// per-port log (`dsh-<port>.log`), which is the file `agent.ps1` writes.
    static func tail(_ machine: Machine, lines: Int) async -> [String] {
        let alias = machine.sshDestination
        let result: SshResult
        if machine.platform == "windows" {
            let script = [
                "$dir = Join-Path $env:USERPROFILE '.dsh\\dshl'",
                "$p = Join-Path $dir 'dsh.log'",
                "if (-not (Test-Path $p)) { $alt = Join-Path $dir ('dsh-' + \(machine.port) + '.log'); if (Test-Path $alt) { $p = $alt } }",
                "Get-Content $p -Tail \(lines) -ErrorAction SilentlyContinue",
            ].joined(separator: "; ")
            result = await SshTransport.runPowerShell(
                alias: alias,
                script: script,
                timeout: RemoteTimeouts.logs
            )
        } else {
            result = await SshTransport.run(
                alias: alias,
                command: "tail -n \(lines) \"$HOME/.dsh/dshl/dsh.log\" 2>/dev/null",
                timeout: RemoteTimeouts.logs
            )
        }
        guard result.exit == 0, !result.stdout.isEmpty else { return [] }
        return result.stdout
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
    }

    // MARK: - Setup

    static func setup(
        _ machine: Machine,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> SetupOutcome {
        await RemoteSetup.run(machine, progress: progress)
    }
}
