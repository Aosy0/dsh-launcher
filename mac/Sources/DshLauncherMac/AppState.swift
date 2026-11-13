import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var config: LauncherConfig
    @Published private(set) var statuses: [String: MachineStatus] = [:]
    @Published private(set) var busy: [String: BusyState] = [:]
    @Published var selectedId: String?
    @Published var statusLine: String = ""
    @Published var isRefreshing: Bool = false
    @Published var clock: Date = Date()
    @Published var confirm: ConfirmRequest?
    @Published var logView: LogViewState?
    @Published var authURL: AuthURLResult?
    @Published var pwaInfo: PwaInfo?
    @Published var setupOutcome: SetupOutcome?
    @Published var errorMessage: String?
    @Published var toast: String?
    @Published var showAddMachine: Bool = false
    @Published var renameTarget: Machine?

    let configPath: String?
    var onNeedsWindow: (() -> Void)?

    private var pollTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var lastLoggedSummary = ""

    init(configPath: String? = nil) {
        self.configPath = configPath
        var loaded = LauncherConfig.load(path: configPath)
        if loaded.localMachine == nil {
            loaded.machines.insert(
                Machine(id: "local", kind: .local, name: HostInfo.computerName),
                at: 0
            )
        }
        self.config = loaded
        self.selectedId = loaded.localMachine?.id
    }

    deinit {
        pollTask?.cancel()
        clockTask?.cancel()
        toastTask?.cancel()
    }

    // MARK: Queries

    var machines: [Machine] { config.machines }

    var localMachine: Machine? {
        config.machines.first { $0.kind == .local }
    }

    func machine(id: String) -> Machine? {
        config.machines.first { $0.id == id }
    }

    func status(for machine: Machine) -> MachineStatus {
        statuses[machine.id] ?? MachineStatus(port: machine.port, url: machine.targetURLString)
    }

    var aggregateText: String {
        let total = config.machines.count
        let running = config.machines.filter { statuses[$0.id]?.state == .running }.count
        let attention = config.machines.filter {
            let state = statuses[$0.id]?.state ?? .unknown
            return state == .needsSetup || state == .unreachable || state == .unknown
        }.count
        var text = "\(total) 台中 \(running) 台稼働"
        if attention > 0 {
            text += " · \(attention) 台要対応"
        }
        return text
    }

    // MARK: Polling

    func startPolling() {
        guard pollTask == nil else {
            Log.write("polling already running")
            return
        }
        Log.write("polling start")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshAll()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.clock = Date()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshAll(force: Bool = false) async {
        if isRefreshing && !force {
            Log.write("refresh skipped (already running)")
            return
        }
        isRefreshing = true
        Log.write("refresh begin machines=\(config.machines.count)")
        defer { isRefreshing = false }
        let machines = config.machines
        let results = await withTaskGroup(of: (String, MachineStatus).self) { group in
            for machine in machines {
                group.addTask {
                    let status = await MachineOps.status(machine)
                    Log.write("status \(machine.id)=\(status.state.rawValue)")
                    return (machine.id, status)
                }
            }
            var collected: [(String, MachineStatus)] = []
            for await item in group { collected.append(item) }
            return collected
        }
        for (id, status) in results {
            statuses[id] = status
        }
        applyPlatformHints(results)
        statusLine = aggregateText
        if statusLine != lastLoggedSummary {
            lastLoggedSummary = statusLine
            let detail = results
                .sorted { $0.0 < $1.0 }
                .map { "\($0.0)=\($0.1.state.rawValue)" }
                .joined(separator: ",")
            Log.write("status: \(statusLine) [\(detail)]")
        }
    }

    func refresh(_ machine: Machine) async {
        let status = await MachineOps.status(machine)
        statuses[machine.id] = status
        if machine.kind == .ssh, machine.platform == "auto", let platform = status.platform {
            updatePlatform(machine, platform: platform)
        }
        statusLine = aggregateText
    }

    private func applyPlatformHints(_ results: [(String, MachineStatus)]) {
        for (id, status) in results {
            guard let machine = machine(id: id),
                  machine.kind == .ssh,
                  machine.platform == "auto",
                  let platform = status.platform,
                  platform.lowercased() != "auto" else { continue }
            updatePlatform(machine, platform: platform)
        }
    }

    private func updatePlatform(_ machine: Machine, platform: String) {
        guard let index = config.machines.firstIndex(where: { $0.id == machine.id }) else { return }
        let value = platform.lowercased()
        guard config.machines[index].platform != value else { return }
        config.machines[index].platform = value
        save()
    }

    // MARK: Actions

    func request(_ action: ActionKind, for machine: Machine) {
        let current = status(for: machine).stateText
        let command = machine.isLocal
            ? LocalMachine.commandLine(machine)
            : RemoteMachine.actionCommand(machine, action.rawValue)
        confirm = ConfirmRequest(
            machine: machine,
            action: action,
            command: command,
            currentState: current
        )
        onNeedsWindow?()
    }

    func performConfirmed() async {
        guard let request = confirm else { return }
        confirm = nil
        await perform(request.action, for: request.machine)
    }

    func perform(_ action: ActionKind, for machine: Machine) async {
        guard busy[machine.id] == nil else { return }
        busy[machine.id] = BusyState(label: action.busyLabel, startedAt: Date())
        statuses[machine.id]?.state = .starting
        let result: (Bool, String)
        switch action {
        case .start:
            result = machine.isLocal
                ? await LocalMachine.start(machine)
                : await RemoteMachine.action(machine, "start")
        case .stop:
            result = machine.isLocal
                ? await LocalMachine.stop(machine)
                : await RemoteMachine.action(machine, "stop")
        case .restart:
            result = machine.isLocal
                ? await LocalMachine.restart(machine)
                : await RemoteMachine.action(machine, "restart")
        }
        busy[machine.id] = nil
        await refresh(machine)
        if result.0 {
            Log.write("\(machine.id) \(action.rawValue) ok: \(result.1)")
            showToast("\(machine.displayName): \(action.title)しました（\(result.1)）")
        } else {
            Log.write("\(machine.id) \(action.rawValue) failed: \(result.1)")
            errorMessage = "\(machine.displayName): \(result.1)"
        }
    }

    func performBusyAction(_ machine: Machine) async {
        if status(for: machine).state == .running {
            await perform(.stop, for: machine)
        } else {
            await perform(.start, for: machine)
        }
    }

    // MARK: Logs

    func showLogs(_ machine: Machine) {
        logView = LogViewState(
            title: "\(machine.displayName) のログ",
            lines: [],
            loading: true,
            message: nil
        )
        onNeedsWindow?()
        Task { [weak self] in
            guard let self else { return }
            let lines = await MachineOps.tail(machine, lines: 200)
            self.logView?.lines = lines
            self.logView?.loading = false
            if lines.isEmpty {
                self.logView?.message = "ログはまだありません"
            }
        }
    }

    func reloadLogs(_ machine: Machine) async {
        let lines = await MachineOps.tail(machine, lines: 200)
        logView?.lines = lines
        logView?.loading = false
        if lines.isEmpty { logView?.message = "ログはまだありません" }
    }

    // MARK: Open / URLs

    func open(_ machine: Machine) {
        guard let url = machine.targetURL else {
            errorMessage = "URL が不正です: \(machine.targetURLString)"
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openURLString(_ text: String) {
        guard let url = URL(string: text) else {
            errorMessage = "URL が不正です: \(text)"
            return
        }
        NSWorkspace.shared.open(url)
    }

    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showToast("コピーしました")
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Auth URL

    func prepareAuthURL(for machine: Machine? = nil) async {
        guard let target = machine ?? localMachine else {
            errorMessage = "ローカルの DSH が見つかりません"
            return
        }
        guard target.isLocal else {
            authURL = AuthURLResult(
                ok: false,
                message: "認証 URL はローカルの DSH でのみ発行できます（v0.1）"
            )
            return
        }
        if let busyLabel = busy[target.id]?.label {
            errorMessage = "\(busyLabel)のため発行できません"
            return
        }
        authURL = await AuthURL.issue(for: target)
        if let result = authURL {
            Log.write("auth-url \(target.id) ok=\(result.ok) message=\(result.message)")
        }
        onNeedsWindow?()
    }

    // MARK: PWA

    func openPWA() async {
        guard let local = localMachine else { return }
        let info = BrowserApp.info(for: local)
        pwaInfo = info
        Log.write("pwa info installed=\(info.installed) app=\(info.appPath ?? "-") message=\(info.message ?? "-")")
        onNeedsWindow?()
        if info.installed {
            let opened = await BrowserApp.open(local)
            pwaInfo = opened
            Log.write("pwa open installed=\(opened.installed) message=\(opened.message ?? "-")")
            if let message = opened.message, !opened.installed {
                errorMessage = message
            }
        }
    }

    // MARK: Machine editing

    func addMachine(name: String, sshAlias: String, port: Int, profile: String, url: String?) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlias = sshAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedAlias.isEmpty else { return }
        var base = Paths.sanitize(trimmedAlias)
        var candidate = base
        var index = 2
        while config.machines.contains(where: { $0.id == candidate }) {
            candidate = "\(base)-\(index)"
            index += 1
        }
        base = candidate
        let machine = Machine(
            id: base,
            kind: .ssh,
            name: trimmedName,
            sshAlias: trimmedAlias,
            platform: "auto",
            profile: profile.isEmpty ? "web" : profile,
            port: port,
            url: url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : url
        )
        config.machines.append(machine)
        save()
        showToast("\(machine.name) を追加しました")
        Task { await refresh(machine) }
    }

    func update(_ machine: Machine) {
        guard let index = config.machines.firstIndex(where: { $0.id == machine.id }) else { return }
        config.machines[index] = machine
        save()
        Task { await refresh(machine) }
    }

    func rename(_ machine: Machine, to name: String) {
        var updated = machine
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.name.isEmpty else { return }
        update(updated)
    }

    func remove(_ machine: Machine) {
        guard !machine.isLocal else { return }
        config.machines.removeAll { $0.id == machine.id }
        statuses.removeValue(forKey: machine.id)
        if selectedId == machine.id { selectedId = localMachine?.id }
        save()
    }

    func save() {
        do {
            try config.save(path: configPath)
        } catch {
            errorMessage = "設定を保存できません: \(error.localizedDescription)"
        }
    }
}
