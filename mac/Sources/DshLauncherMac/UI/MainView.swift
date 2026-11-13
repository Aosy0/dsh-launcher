import Foundation
import SwiftUI

/// The single window: header, grouped machine list with one inline detail
/// panel, and a fixed bottom bar. Everything talks to `AppState`; the arrays in
/// the config are never edited here.
@MainActor
struct MainView: View {
    @ObservedObject var state: AppState

    private enum ActiveDialog: Identifiable {
        case confirm
        case logs
        case addMachine
        case rename(Machine)
        case authURL
        case pwa
        case error

        var id: String {
            switch self {
            case .confirm:
                return "confirm"
            case .logs:
                return "logs"
            case .addMachine:
                return "addMachine"
            case .rename(let machine):
                return "rename-\(machine.id)"
            case .authURL:
                return "authURL"
            case .pwa:
                return "pwa"
            case .error:
                return "error"
            }
        }
    }

    private struct MachineSection: Identifiable {
        let id: String
        let title: String
        let machines: [Machine]
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                Hairline()
                machineList
                Hairline()
                bottomBar
            }
            toast
        }
        .background(Theme.page.ignoresSafeArea())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.16), value: state.toast)
        .sheet(item: dialogItem) { dialog in
            dialogContent(dialog)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("DSH")
                .font(Theme.wordmark)
                .foregroundStyle(Theme.text)
            Text(state.aggregateText)
                .font(Theme.aggregate)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            refreshControl
        }
        .padding(.horizontal, Metrics.headerPaddingH)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var refreshControl: some View {
        if state.isRefreshing {
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: 26)
        } else {
            IconButton(symbol: "arrow.clockwise", label: "状態を更新") {
                Task { @MainActor in await state.refreshAll(force: true) }
            }
        }
    }

    // MARK: - List

    private var machineList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if sections.isEmpty {
                        emptyState
                    } else {
                        ForEach(sections) { section in
                            SectionHeader(title: section.title, count: section.machines.count)
                                .padding(.horizontal, Metrics.listPaddingH)
                                .padding(.top, Metrics.sectionTopPadding)
                                .padding(.bottom, 2)
                            ForEach(section.machines) { machine in
                                MachineRow(state: state, machine: machine)
                                    .padding(.horizontal, Metrics.listPaddingH)
                                    .id(machine.id)
                                if state.selectedId == machine.id {
                                    MachineDetailPanel(state: state, machine: machine)
                                        .padding(.leading, Metrics.listPaddingH + Metrics.detailIndent)
                                        .padding(.trailing, Metrics.listPaddingH)
                                        .padding(.bottom, 6)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: state.selectedId) { newValue in
                guard let id = newValue else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("マシンがありません")
                .font(Theme.body)
                .foregroundStyle(Theme.secondary)
            Text("「マシンを追加」から SSH のマシンを追加してください。")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var sections: [MachineSection] {
        var running: [Machine] = []
        var attention: [Machine] = []
        var stopped: [Machine] = []

        for machine in state.machines {
            switch state.status(for: machine).state {
            case .running, .starting:
                running.append(machine)
            case .needsSetup, .unreachable, .unknown:
                attention.append(machine)
            case .stopped:
                stopped.append(machine)
            }
        }

        var result: [MachineSection] = []
        if !running.isEmpty {
            result.append(MachineSection(id: "running", title: "稼働中", machines: sorted(running)))
        }
        if !attention.isEmpty {
            result.append(MachineSection(id: "attention", title: "要対応", machines: sorted(attention)))
        }
        if !stopped.isEmpty {
            result.append(MachineSection(id: "stopped", title: "停止", machines: sorted(stopped)))
        }
        return result
    }

    /// Local first, then by display name so groups do not reshuffle on refresh.
    private func sorted(_ machines: [Machine]) -> [Machine] {
        machines.sorted { lhs, rhs in
            if lhs.isLocal != rhs.isLocal { return lhs.isLocal }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            SmallButton("マシンを追加", kind: .quiet, symbol: "plus") {
                state.showAddMachine = true
            }
            Spacer(minLength: 8)
            SmallButton("ログ", kind: .quiet, symbol: "doc.text") {
                openSelectedLogs()
            }
            SmallButton("PWA を開く", kind: .primary, symbol: "square.and.arrow.up") {
                openPWA()
            }
            SmallButton("認証 URL", kind: .secondary, symbol: "link") {
                issueAuthURL()
            }
        }
        .padding(.horizontal, Metrics.bottomBarPaddingH)
        .frame(height: Metrics.bottomBarHeight)
    }

    private var selectedMachine: Machine? {
        if let id = state.selectedId,
           let found = state.machines.first(where: { $0.id == id }) {
            return found
        }
        return state.localMachine
    }

    private func openSelectedLogs() {
        guard let machine = selectedMachine else { return }
        state.showLogs(machine)
    }

    /// Opening the PWA should not leave a sheet behind on the happy path;
    /// only a missing install or a failure is worth a dialog.
    private func openPWA() {
        Task { @MainActor in
            await state.openPWA()
            if state.pwaInfo?.installed == true, state.pwaInfo?.message == nil {
                state.pwaInfo = nil
            }
        }
    }

    private func issueAuthURL() {
        Task { @MainActor in
            await state.prepareAuthURL(for: state.localMachine)
        }
    }

    // MARK: - Toast

    @ViewBuilder
    private var toast: some View {
        if let text = state.toast {
            ToastBar(text: text)
                .padding(.bottom, Metrics.toastBottomInset)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .allowsHitTesting(false)
                .zIndex(1)
        }
    }

    // MARK: - Dialog routing

    /// One sheet modifier, one active dialog. Priority keeps a receipt on top of
    /// informational sheets; errors wait until the current sheet closes.
    private var activeDialog: ActiveDialog? {
        if state.confirm != nil { return .confirm }
        if state.logView != nil { return .logs }
        if state.showAddMachine { return .addMachine }
        if let machine = state.renameTarget { return .rename(machine) }
        if state.authURL != nil { return .authURL }
        if let info = state.pwaInfo {
            if !(info.installed && info.message == nil) { return .pwa }
        }
        if state.errorMessage != nil { return .error }
        return nil
    }

    private var dialogItem: Binding<ActiveDialog?> {
        Binding(
            get: { activeDialog },
            set: { item in
                if item == nil { dismissActiveDialog() }
            }
        )
    }

    @ViewBuilder
    private func dialogContent(_ dialog: ActiveDialog) -> some View {
        switch dialog {
        case .confirm:
            ConfirmDialog(state: state, dismiss: { dismissActiveDialog() })
        case .logs:
            LogsDialog(state: state, dismiss: { dismissActiveDialog() })
        case .addMachine:
            AddMachineDialog(state: state, dismiss: { dismissActiveDialog() })
        case .rename(let machine):
            RenameDialog(state: state, machine: machine, dismiss: { dismissActiveDialog() })
        case .authURL:
            AuthURLDialog(state: state, dismiss: { dismissActiveDialog() })
        case .pwa:
            PwaDialog(state: state, dismiss: { dismissActiveDialog() })
        case .error:
            ErrorDialog(state: state, dismiss: { dismissActiveDialog() })
        }
    }

    private func dismissActiveDialog() {
        guard let dialog = activeDialog else { return }
        switch dialog {
        case .confirm:
            state.confirm = nil
        case .logs:
            state.logView = nil
        case .addMachine:
            state.showAddMachine = false
        case .rename:
            state.renameTarget = nil
        case .authURL:
            state.authURL = nil
        case .pwa:
            state.pwaInfo = nil
        case .error:
            state.errorMessage = nil
        }
    }
}

// MARK: - Row

@MainActor
private struct MachineRow: View {
    @ObservedObject var state: AppState
    let machine: Machine

    @State var hovering = false

    private var status: MachineStatus { state.status(for: machine) }
    private var selected: Bool { state.selectedId == machine.id }
    private var busy: BusyState? { state.busy[machine.id] }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: status.state)
            Text(machine.displayName)
                .font(Theme.rowName)
                .foregroundStyle(selected ? Theme.text : Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            readout
        }
        .padding(.horizontal, 10)
        .frame(height: Metrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Metrics.rowRadius)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.rowRadius)
                .strokeBorder(selected ? Theme.hairlineStrong : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Metrics.rowRadius))
        .onTapGesture { state.selectedId = machine.id }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu { menu }
        .padding(.bottom, 2)
    }

    private var background: Color {
        if selected { return Theme.card }
        return hovering ? Color.white.opacity(0.025) : Color.clear
    }

    @ViewBuilder
    private var readout: some View {
        if let busy = busy {
            Text("\(busy.label) \(busy.elapsedText)")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.attention)
        } else {
            HStack(spacing: 8) {
                Text(status.stateText)
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.secondary)
                if !metaText.isEmpty {
                    Text(metaText)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.secondary.opacity(0.72))
                        .lineLimit(1)
                }
            }
        }
    }

    /// PID / port / latency: readouts, monospaced.
    private var metaText: String {
        var parts: [String] = []
        if machine.kind == .ssh, status.dshInstalled == false {
            parts.append("dsh 未導入")
        } else if status.state == .running, let pid = status.pid {
            parts.append("PID \(pid)")
        }
        parts.append("\(machine.port)")
        if machine.kind == .ssh, status.state != .unreachable, let latency = status.latencyMs {
            parts.append("\(latency) ms")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var menu: some View {
        Button("名前を変更…") { state.renameTarget = machine }
        Button("ブラウザで開く") { state.open(machine) }
        Button("URL をコピー") { state.copy(machine.targetURLString) }
        Divider()
        if status.state == .running {
            Button("再起動…") { state.request(.restart, for: machine) }
                .disabled(busy != nil)
            Button("停止…") { state.request(.stop, for: machine) }
                .disabled(busy != nil)
        } else {
            Button("起動…") { state.request(.start, for: machine) }
                .disabled(busy != nil)
        }
        Divider()
        Button("ログを開く") { state.showLogs(machine) }
    }
}

// MARK: - Detail panel

@MainActor
private struct MachineDetailPanel: View {
    @ObservedObject var state: AppState
    let machine: Machine

    private var status: MachineStatus { state.status(for: machine) }
    private var busy: BusyState? { state.busy[machine.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            urlSection
            factsSection
            notesSection
            CommandReceipt(title: "実行されるコマンド", command: commandText) {
                state.copy($0)
            }
            actionRow
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    private var urlSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("URL")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 8)
                QuietButton("開く", symbol: "arrow.up.right.square") { state.open(machine) }
                QuietButton("コピー", symbol: "doc.on.doc") {
                    state.copy(machine.targetURLString)
                }
            }
            Text(machine.targetURLString)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var factsSection: some View {
        Text(factsText)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var notesSection: some View {
        if let note = status.note, !note.isEmpty {
            Text(note)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let error = status.error, !error.isEmpty {
            Text(error)
                .font(Theme.caption)
                .foregroundStyle(Theme.danger.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            actionButtons
            Spacer(minLength: 8)
            if let busy = busy {
                ProgressView()
                    .controlSize(.small)
                Text("\(busy.label) \(busy.elapsedText)")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.attention)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if status.state == .running {
            SmallButton(
                "再起動",
                kind: .primary,
                symbol: "arrow.clockwise",
                enabled: busy == nil
            ) {
                state.request(.restart, for: machine)
            }
            SmallButton(
                "停止",
                kind: .secondary,
                symbol: "stop.fill",
                enabled: busy == nil
            ) {
                state.request(.stop, for: machine)
            }
        } else {
            SmallButton(
                "起動",
                kind: .primary,
                symbol: "play.fill",
                enabled: busy == nil
            ) {
                state.request(.start, for: machine)
            }
        }
        SmallButton("ログ", kind: .secondary, symbol: "doc.text") {
            state.showLogs(machine)
        }
    }

    private var factsText: String {
        var parts: [String] = []
        if let pid = status.pid { parts.append("PID \(pid)") }
        parts.append("ポート \(machine.port)")
        if let uptime = status.uptimeText { parts.append("稼働 \(uptime)") }
        if let memory = status.memoryText { parts.append("メモリ \(memory)") }
        if let node = status.nodeVersion { parts.append("Node \(node)") }
        if machine.kind == .ssh, let latency = status.latencyMs { parts.append("\(latency) ms") }
        if status.dshInstalled == false { parts.append("dsh 未導入") }
        if status.dshHome == false { parts.append("~/.dsh なし") }
        return parts.joined(separator: " · ")
    }

    private var commandText: String {
        if let command = status.command, !command.isEmpty { return command }
        return MachineOps.displayCommand(machine, verb: machine.isLocal ? "restart" : "status")
    }
}
