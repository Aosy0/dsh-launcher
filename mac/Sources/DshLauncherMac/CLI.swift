import AppKit
import Foundation
import SwiftUI

/// `dshl` CLI. The same binary runs the GUI when invoked without arguments.
enum CLI {
    private struct Options {
        var json = false
        var all = false
        var yes = false
        var dryRun = false
        var install = false
        var open = false
        var copy = false
        var check = false
        var config: String?
        var lines = 50
        var positionals: [String] = []
    }

    static func run(_ args: [String]) async -> Int32 {
        if args.contains("--version") || args.contains("-V") {
            print(AppInfo.version)
            return 0
        }

        var options = Options()
        var positionals: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--json": options.json = true
            case "--all": options.all = true
            case "--yes", "-y": options.yes = true
            case "--dry-run": options.dryRun = true
            case "--install": options.install = true
            case "--open": options.open = true
            case "--copy": options.copy = true
            case "--check": options.check = true
            case "-h", "--help":
                printHelp()
                return 0
            case "--config":
                if index + 1 < args.count {
                    options.config = args[index + 1]
                    index += 1
                }
            case "-n":
                if index + 1 < args.count, let lines = Int(args[index + 1]) {
                    options.lines = lines
                    index += 1
                }
            default:
                if arg.hasPrefix("-") {
                    fail("unknown option: \(arg)")
                    return 1
                }
                if arg == "version" {
                    print(AppInfo.version)
                    return 0
                }
                positionals.append(arg)
            }
            index += 1
        }
        options.positionals = positionals

        var config = LauncherConfig.load(path: options.config)
        let command = positionals.first ?? "status"
        let target = positionals.count > 1 ? positionals[1] : nil

        func machine(_ name: String?) -> Machine? {
            if let name, !name.isEmpty {
                return config.find(name)
            }
            return config.localMachine
        }

        func resolveOrFail(_ name: String?) -> Machine? {
            guard let value = machine(name) else {
                fail("machine not found: \(name ?? "")")
                return nil
            }
            return value
        }

        var code: Int32 = 0
        switch command {
        case "status":
            code = await status(config: &config, options: options, target: target)
        case "machines", "list":
            code = list(config: config, options: options)
        case "start", "stop", "restart":
            guard let value = resolveOrFail(target) else { return 1 }
            code = await action(config: &config, options: options, machine: value, verb: command)
        case "url":
            guard let value = resolveOrFail(target) else { return 1 }
            print(value.targetURLString)
        case "logs":
            guard let value = resolveOrFail(target) else { return 1 }
            let lines = await MachineOps.tail(value, lines: options.lines)
            for line in lines { print(line) }
        case "setup":
            guard let value = resolveOrFail(target) else { return 1 }
            code = await setup(config: &config, options: options, machine: value)
        case "rename":
            guard positionals.count >= 3, let value = resolveOrFail(target) else {
                fail("usage: dshl rename <machine> <name>")
                return 1
            }
            var updated = value
            updated.name = positionals[2].trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = config.machines.firstIndex(where: { $0.id == value.id }) {
                config.machines[index] = updated
            }
            print("\(value.id): \(updated.displayName)")
        case "add":
            guard positionals.count >= 3,
                  let alias = positionals.count > 2 ? positionals[2] : nil else {
                fail("usage: dshl add <name> <ssh-alias> [platform]")
                return 1
            }
            let name = positionals[1]
            if config.machines.contains(where: { $0.id == name }) {
                fail("machine already exists: \(name)")
                return 1
            }
            let platform = positionals.count > 3 ? positionals[3].lowercased() : "auto"
            let added = Machine(
                id: name,
                kind: .ssh,
                name: name,
                sshAlias: alias.trimmingCharacters(in: .whitespacesAndNewlines),
                platform: platform
            )
            config.machines.append(added)
            print("added \(added.displayName)")
        case "remove", "rm":
            guard let value = resolveOrFail(target) else { return 1 }
            guard !value.isLocal else {
                fail("the local machine cannot be removed")
                return 1
            }
            config.machines.removeAll { $0.id == value.id }
            print("removed \(value.displayName)")
        case "open":
            guard let value = resolveOrFail(target) else { return 1 }
            if options.dryRun {
                print(value.targetURLString)
            } else {
                _ = await Shell.run("/usr/bin/open", [value.targetURLString], timeout: 10)
                print(value.targetURLString)
            }
        case "pwa":
            code = await pwa(config: &config, options: options)
        case "auth-url", "token":
            guard let value = resolveOrFail(target) else { return 1 }
            code = await authURL(machine: value, options: options)
        case "gui":
            // Handled by the dispatcher before CLI.run.
            code = 0
        case "update":
            fail("macOS 版の自動更新は未対応です（ビルドし直してください）")
            code = 2
        default:
            fail("unknown command: \(command)")
            printHelp()
            code = 1
        }

        try? config.save(path: options.config)
        return code
    }

    // MARK: Commands

    private static func status(
        config: inout LauncherConfig,
        options: Options,
        target: String?
    ) async -> Int32 {
        var machines: [Machine]
        if let target, !target.isEmpty {
            guard let found = config.find(target) else {
                fail("machine not found: \(target)")
                return 1
            }
            machines = [found]
        } else {
            machines = config.machines
        }
        var statuses: [(Machine, MachineStatus)] = []
        for original in machines {
            var machine = original
            let status = await MachineOps.status(machine)
            if machine.kind == .ssh, machine.platform == "auto", let platform = status.platform {
                let value = platform.lowercased()
                if value != "auto" {
                    machine.platform = value
                    if let index = config.machines.firstIndex(where: { $0.id == machine.id }) {
                        config.machines[index].platform = value
                    }
                }
            }
            statuses.append((machine, status))
        }

        if options.json {
            let payload = statuses.map { pair -> StatusJSON in
                let (machine, status) = pair
                return StatusJSON(
                    id: machine.id,
                    name: machine.name,
                    displayName: machine.displayName,
                    kind: machine.kind == .local ? "local" : "ssh",
                    platform: machine.platform,
                    state: status.stateText,
                    pid: status.pid,
                    port: status.port,
                    uptimeSeconds: status.uptimeSeconds,
                    memoryMb: status.memoryMb,
                    url: status.url,
                    note: status.note,
                    nodeVersion: status.nodeVersion,
                    dshInstalled: status.dshInstalled,
                    error: status.error,
                    latencyMs: status.latencyMs,
                    command: status.command
                )
            }
            print(JsonTool.encode(payload))
        } else {
            for (machine, status) in statuses {
                var details = [status.stateText]
                if let pid = status.pid { details.append("PID \(pid)") }
                if let uptime = status.uptimeText { details.append(uptime) }
                if let memory = status.memoryText { details.append(memory) }
                if let latency = status.latencyMs { details.append("\(latency) ms") }
                if let note = status.note, !note.isEmpty { details.append(note) }
                if let error = status.error, !error.isEmpty { details.append(error) }
                let name = machine.displayName.count >= 22
                    ? machine.displayName + " "
                    : machine.displayName.padding(toLength: 22, withPad: " ", startingAt: 0)
                print("\(name)\(details.joined(separator: "  "))")
            }
        }
        return exitCode(statuses.map(\.1))
    }

    private static func list(config: LauncherConfig, options: Options) -> Int32 {
        if options.json {
            let payload = config.machines.map { machine in
                MachineJSON(
                    id: machine.id,
                    name: machine.name,
                    displayName: machine.displayName,
                    kind: machine.kind == .local ? "local" : "ssh",
                    platform: machine.platform,
                    sshAlias: machine.sshAlias,
                    profile: machine.profile,
                    port: machine.port,
                    url: machine.url,
                    pinned: machine.pinned
                )
            }
            print(JsonTool.encode(payload))
        } else {
            for machine in config.machines {
                var line = "\(machine.displayName)  (\(machine.id))  port \(machine.port)"
                if machine.kind == .ssh { line += "  \(machine.platform)" }
                print(line)
            }
        }
        return 0
    }

    private static func action(
        config: inout LauncherConfig,
        options: Options,
        machine: Machine,
        verb: String
    ) async -> Int32 {
        if options.dryRun {
            print(MachineOps.displayCommand(machine, verb: verb))
            return 0
        }
        let result: (Bool, String)
        if machine.isLocal {
            switch verb {
            case "start": result = await LocalMachine.start(machine)
            case "stop": result = await LocalMachine.stop(machine)
            default: result = await LocalMachine.restart(machine)
            }
        } else {
            result = await RemoteMachine.action(machine, verb)
        }
        if options.json {
            print(JsonTool.encode(ActionJSON(machine: machine.id, action: verb, ok: result.0, message: result.1)))
        } else {
            print("\(machine.displayName): \(verb) -> \(result.0 ? "ok" : "failed") (\(result.1))")
        }
        if !result.0, result.1.lowercased().hasPrefix("needs setup") { return 4 }
        return result.0 ? 0 : 1
    }

    private static func setup(
        config: inout LauncherConfig,
        options: Options,
        machine: Machine
    ) async -> Int32 {
        if machine.isLocal {
            print("local machine needs no helper")
            return 0
        }
        if !options.install {
            let result = await MachineOps.deploy(machine)
            print(result.0 ? "installed: \(result.1)" : "failed: \(result.1)")
            return result.0 ? 0 : 1
        }
        if options.dryRun {
            for line in RemoteSetup.plan(machine) { print(line) }
            return 0
        }
        let outcome = await RemoteMachine.setup(machine, progress: { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        })
        if options.json {
            print(JsonTool.encode(SetupJSON(
                machine: machine.id,
                ok: outcome.ok,
                message: outcome.message,
                steps: outcome.steps
            )))
        } else {
            for step in outcome.steps {
                print("\(step.name): \(step.state) \(step.detail)")
            }
            print(outcome.message)
        }
        return outcome.ok ? 0 : 1
    }

    private static func pwa(config: inout LauncherConfig, options: Options) async -> Int32 {
        guard let local = config.localMachine else {
            fail("local machine is not configured")
            return 1
        }
        let info = BrowserApp.info(for: local)
        let browserNames = info.browsers.map(\.name)

        if !info.installed {
            let hint = browserNames.isEmpty
                ? "PWA に対応したブラウザが見つかりません。Chromium 系のブラウザをインストールしてください。"
                : "ブラウザでこの URL を開き、「アプリとしてインストール」で追加します（Chromium 系のブラウザが必要です）。"
            if options.json {
                print(JsonTool.encode(PwaJSON(
                    machine: local.id,
                    url: local.targetURLString,
                    browserFound: !browserNames.isEmpty,
                    browsers: browserNames,
                    installed: false,
                    appId: nil,
                    name: nil,
                    browser: nil,
                    appPath: nil,
                    command: nil,
                    hint: hint
                )))
            } else {
                print(browserNames.isEmpty
                    ? "PWA に対応したブラウザが見つかりません"
                    : "PWA はインストールされていません: \(local.targetURLString)")
                print("hint: \(hint)")
            }
            return 4
        }

        let commandLine: String
        if let appPath = info.appPath {
            commandLine = "/usr/bin/open -a \(appPath)"
        } else {
            commandLine = "/usr/bin/open \(local.targetURLString)"
        }
        if options.dryRun {
            print(commandLine)
            return 0
        }
        if !options.open {
            if options.json {
                print(JsonTool.encode(PwaJSON(
                    machine: local.id,
                    url: local.targetURLString,
                    browserFound: true,
                    browsers: browserNames,
                    installed: true,
                    appId: info.appId,
                    name: info.appName,
                    browser: info.browser,
                    appPath: info.appPath,
                    command: commandLine,
                    hint: info.message
                )))
            } else {
                print("\(info.appName ?? "DSH")  \(info.appId ?? "")  \(info.appPath ?? "")  \(local.targetURLString)")
                print(commandLine)
            }
            return 0
        }

        let opened = await BrowserApp.open(local)
        if options.json {
            print(JsonTool.encode(PwaOpenJSON(
                machine: local.id,
                ok: opened.installed,
                appId: opened.appId,
                name: opened.appName,
                browser: opened.browser,
                command: commandLine,
                message: opened.message ?? ""
            )))
        } else {
            print(opened.message ?? (opened.installed ? "opened" : "ブラウザで開きました"))
        }
        return opened.installed ? 0 : 0
    }

    private static func authURL(machine: Machine, options: Options) async -> Int32 {
        let result = await AuthURL.issue(for: machine)
        if result.ok {
            if options.copy, let url = result.url {
                _ = await Shell.run("/usr/bin/pbcopy", timeout: 5, stdin: url)
            }
            if options.open, let url = result.url {
                _ = await Shell.run("/usr/bin/open", [url], timeout: 10)
            }
        }
        if options.json {
            print(JsonTool.encode(AuthURLJSON(
                machine: machine.id,
                ok: result.ok,
                url: result.url,
                localUrl: result.localUrl,
                externalUrl: result.externalUrl,
                pid: result.pid,
                message: result.message
            )))
        } else if result.ok, let url = result.url {
            print(url)
        } else {
            fail(result.message)
        }
        return result.ok ? 0 : 1
    }

    // MARK: Snapshot (development aid)

    /// Render the main window off-screen to a PNG. SSH sessions cannot use
    /// `screencapture` (TCC), so this is how the UI is inspected during development.
    /// Not part of the user-facing command set.
    static func renderSnapshot(output: String, configPath: String?) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        var state: AppState?
        var hosting: NSHostingView<MainView>?
        MainActor.assumeIsolated {
            let created = AppState(configPath: configPath)
            state = created
            let view = NSHostingView(rootView: MainView(state: created))
            view.frame = NSRect(x: 0, y: 0, width: 520, height: 620)
            view.appearance = NSAppearance(named: .darkAqua)
            hosting = view
            created.startPolling()
        }

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let complete = MainActor.assumeIsolated {
                guard let state else { return true }
                return !state.statuses.isEmpty && state.statuses.count >= state.machines.count
            }
            if complete { break }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        var ok = false
        MainActor.assumeIsolated {
            guard let hosting else { return }
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                return
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            do {
                try data.write(to: URL(fileURLWithPath: output))
                ok = true
            } catch {
                FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
            }
        }
        if ok {
            print("wrote \(output)")
            return 0
        }
        return 1
    }

    // MARK: Helpers

    private static func exitCode(_ statuses: [MachineStatus]) -> Int32 {
        if statuses.contains(where: { $0.state == .needsSetup }) { return 4 }
        if statuses.contains(where: { $0.state == .unreachable }) { return 3 }
        return 0
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("dshl: \(message)\n".utf8))
    }

    static func printHelp() {
        print("""
        dshl — DeepSeek Harness launcher (macOS)

        usage:
          dshl status [machine] [--all] [--json]
          dshl start|stop|restart [machine] [--yes] [--dry-run] [--json]
          dshl machines [--json]
          dshl url [machine]
          dshl logs [machine] [-n 50]
          dshl setup [machine] [--install] [--dry-run]
                                        deploy the helper, or install Node 24.9+ and dsh
          dshl rename <machine> <name>
          dshl add <name> <ssh-alias> [linux|windows|macos]
          dshl remove <machine>
          dshl open [machine] [--dry-run]
                                        open the URL in the default browser
          dshl pwa [--open] [--dry-run] [--json]
                                        this Mac's DSH as an installed web app
          dshl auth-url [machine] [--copy] [--open] [--json]
                                        issue the ?token= URL for a new browser
          dshl gui [--config <path>]    open the launcher window
          --config <path>               use a different hosts.json

        exit codes: 0 ok / 1 error / 2 no change / 3 unreachable / 4 needs setup
        """)
    }
}

// MARK: - JSON payloads

private struct StatusJSON: Encodable {
    var id: String
    var name: String
    var displayName: String
    var kind: String
    var platform: String
    var state: String
    var pid: Int?
    var port: Int?
    var uptimeSeconds: Double?
    var memoryMb: Int?
    var url: String?
    var note: String?
    var nodeVersion: String?
    var dshInstalled: Bool?
    var error: String?
    var latencyMs: Int?
    var command: String?
}

private struct MachineJSON: Encodable {
    var id: String
    var name: String
    var displayName: String
    var kind: String
    var platform: String
    var sshAlias: String?
    var profile: String
    var port: Int
    var url: String?
    var pinned: Bool
}

private struct ActionJSON: Encodable {
    var machine: String
    var action: String
    var ok: Bool
    var message: String
}

private struct SetupJSON: Encodable {
    var machine: String
    var ok: Bool
    var message: String
    var steps: [SetupStep]
}

private struct PwaJSON: Encodable {
    var machine: String
    var url: String
    var browserFound: Bool
    var browsers: [String]
    var installed: Bool
    var appId: String?
    var name: String?
    var browser: String?
    var appPath: String?
    var command: String?
    var hint: String?
}

private struct PwaOpenJSON: Encodable {
    var machine: String
    var ok: Bool
    var appId: String?
    var name: String?
    var browser: String?
    var command: String?
    var message: String
}

private struct AuthURLJSON: Encodable {
    var machine: String
    var ok: Bool
    var url: String?
    var localUrl: String?
    var externalUrl: String?
    var pid: Int?
    var message: String
}
