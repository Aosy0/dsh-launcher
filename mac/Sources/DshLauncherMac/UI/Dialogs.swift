import Foundation
import SwiftUI

// MARK: - Shell

/// Shared dialog chrome: title, optional subtitle, content, hairline, footer.
/// Sheets stay on the same graphite surfaces as the window: card #19191b.
struct DialogShell<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String?
    let width: CGFloat
    let content: Content
    let footer: Footer

    init(
        title: String,
        subtitle: String? = nil,
        width: CGFloat = Metrics.dialogWidth,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Theme.dialogTitle)
                    .foregroundStyle(Theme.text)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(Theme.body)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
            Hairline()
                .padding(.top, 14)
            footer
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
        }
        .padding(Metrics.dialogPadding)
        .frame(width: width)
        .background(Theme.card)
    }
}

// MARK: - Confirm (command receipt)

/// Every major action passes through here: target, current state and the exact
/// command are shown before anything runs. No red buttons; the primary action
/// keeps the off-white treatment.
@MainActor
struct ConfirmDialog: View {
    @ObservedObject var state: AppState
    let dismiss: () -> Void

    var body: some View {
        if let request = state.confirm {
            DialogShell(
                title: "\(request.machine.displayName) を\(request.action.title)しますか",
                subtitle: bodyText(for: request.action),
                width: 440
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    currentStateRow(request)
                    CommandReceipt(command: request.command) { state.copy($0) }
                    if let note = request.note, !note.isEmpty {
                        Text(note)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } footer: {
                HStack(spacing: 8) {
                    QuietButton("受領書をコピー") { copyReceipt(request) }
                    Spacer(minLength: 8)
                    SmallButton("キャンセル", kind: .secondary) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    SmallButton("実行", kind: .primary) {
                        Task { @MainActor in await state.performConfirmed() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        } else {
            EmptyView()
        }
    }

    private func bodyText(for action: ActionKind) -> String {
        switch action {
        case .start:
            return "dsh をバックグラウンドで起動します。完了すると状態が「稼働中」になります。"
        case .restart:
            return "実行中のセッションは中断され、ページは再接続します。停止と起動で最大 90 秒かかります。"
        case .stop:
            return "実行中のセッションは中断されます。"
        }
    }

    private func currentStateRow(_ request: ConfirmRequest) -> some View {
        HStack(spacing: 6) {
            Text("現在の状態")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
            Text(request.currentState)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.text)
            Text("·")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary.opacity(0.6))
            Text(request.machine.isLocal ? "この PC" : "SSH \(request.machine.sshDestination)")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func copyReceipt(_ request: ConfirmRequest) {
        let text = "\(request.machine.displayName) を\(request.action.title)\n"
            + "現在: \(request.currentState)\n"
            + request.command
        state.copy(text)
    }
}

// MARK: - Logs

@MainActor
struct LogsDialog: View {
    @ObservedObject var state: AppState
    let dismiss: () -> Void

    var body: some View {
        if let log = state.logView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(log.title)
                        .font(Theme.dialogTitle)
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                    if log.loading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                logBody(log)
                if let message = log.message, !message.isEmpty {
                    Text(message)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .padding(.top, 6)
                }
                Hairline()
                    .padding(.top, 14)
                HStack(spacing: 14) {
                    QuietButton("コピー", symbol: "doc.on.doc") {
                        state.copy(log.lines.joined(separator: "\n"))
                    }
                    QuietButton("再読み込み", symbol: "arrow.clockwise") { reload() }
                    Spacer(minLength: 8)
                    SmallButton("閉じる", kind: .secondary) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.top, 12)
            }
            .padding(Metrics.dialogPadding)
            .frame(width: Metrics.logDialogWidth)
            .background(Theme.card)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func logBody(_ log: LogViewState) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(log.lines.indices, id: \.self) { index in
                        Text(log.lines[index].isEmpty ? " " : log.lines[index])
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(10)
            }
            .frame(height: 280)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius)
                    .fill(Theme.deep)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .padding(.top, 10)
            .onChange(of: log.lines.count) { _ in
                guard let last = log.lines.indices.last else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private func reload() {
        guard let machine = machineForLogs() else { return }
        Task { @MainActor in await state.reloadLogs(machine) }
    }

    /// LogViewState carries only its title; the title is always
    /// `<displayName> のログ`, so the machine can be recovered for a reload
    /// even when the dialog was opened from the tray.
    private func machineForLogs() -> Machine? {
        if let title = state.logView?.title,
           let match = state.machines.first(where: { "\($0.displayName) のログ" == title }) {
            return match
        }
        if let id = state.selectedId,
           let selected = state.machines.first(where: { $0.id == id }) {
            return selected
        }
        return state.localMachine
    }
}

// MARK: - Add machine

@MainActor
struct AddMachineDialog: View {
    @ObservedObject var state: AppState
    let dismiss: () -> Void

    @State var name = ""
    @State var alias = ""
    @State var port = "3080"
    @State var profile = "web"
    @State var url = ""
    @FocusState var focus: Field?

    enum Field: Hashable {
        case name
        case alias
        case port
        case profile
        case url
    }

    var body: some View {
        DialogShell(
            title: "マシンを追加",
            subtitle: "SSH（~/.ssh/config の Host）で接続するマシンを一覧に追加します。",
            width: 430
        ) {
            VStack(alignment: .leading, spacing: 10) {
                input("名前", text: $name, key: .name, prompt: "表示名")
                input("SSH エイリアス", text: $alias, key: .alias, prompt: "minipc-server")
                input("ポート", text: $port, key: .port, prompt: "3080")
                input("プロファイル", text: $profile, key: .profile, prompt: "web")
                input("URL（任意）", text: $url, key: .url, prompt: "https://…")
            }
        } footer: {
            HStack(spacing: 8) {
                Spacer(minLength: 8)
                SmallButton("キャンセル", kind: .secondary) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                SmallButton("追加", kind: .primary, enabled: canSubmit) { submit() }
            }
        }
        .onAppear {
            DispatchQueue.main.async { focus = .name }
        }
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func input(
        _ label: String,
        text: Binding<String>,
        key: Field,
        prompt: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(Theme.sans(12))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.inputRadius)
                        .fill(Theme.deep)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.inputRadius)
                        .strokeBorder(Theme.hairlineStrong, lineWidth: 1)
                )
                .focused($focus, equals: key)
                .onSubmit { submit() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func submit() {
        guard canSubmit else { return }
        let parsedPort = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 3080
        let trimmedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        state.addMachine(
            name: name,
            sshAlias: alias,
            port: parsedPort,
            profile: trimmedProfile.isEmpty ? "web" : trimmedProfile,
            url: trimmedURL.isEmpty ? nil : trimmedURL
        )
        dismiss()
    }
}

// MARK: - Rename / delete

@MainActor
struct RenameDialog: View {
    @ObservedObject var state: AppState
    let machine: Machine
    let dismiss: () -> Void

    @State private var name: String
    @State private var confirmDelete = false
    @FocusState private var focused: Bool

    init(state: AppState, machine: Machine, dismiss: @escaping () -> Void) {
        self.state = state
        self.machine = machine
        self.dismiss = dismiss
        _name = State(initialValue: machine.name)
    }

    var body: some View {
        DialogShell(
            title: "名前を変更",
            subtitle: "\(machine.id) の表示名",
            width: 380
        ) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("表示名", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.inputRadius)
                            .fill(Theme.deep)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.inputRadius)
                            .strokeBorder(Theme.hairlineStrong, lineWidth: 1)
                    )
                    .focused($focused)
                    .onSubmit { save() }
                Text("表示: \(previewName)")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.secondary)
                Text(machine.isLocal
                     ? "この PC の行は名前を変更できます。一覧から削除はできません。"
                     : "SSH の行は名前を変更できます。削除すると一覧から外れ、DSH のプロセスには触れません。")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        } footer: {
            HStack(spacing: 8) {
                if !machine.isLocal {
                    QuietButton(
                        "削除…",
                        symbol: "trash",
                        color: Theme.danger,
                        hoverColor: Theme.danger
                    ) {
                        confirmDelete = true
                    }
                }
                Spacer(minLength: 8)
                SmallButton("キャンセル", kind: .secondary) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                SmallButton("保存", kind: .primary, enabled: canSave) { save() }
            }
        }
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
        .alert("「\(machine.name)」を削除しますか", isPresented: $confirmDelete) {
            Button("削除", role: .destructive) {
                state.remove(machine)
                dismiss()
            }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("一覧から削除します。DSH の実行状態やリモートの設定は変更しません。")
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var previewName: String {
        machine.isLocal ? "\(trimmedName)(local)" : trimmedName
    }

    private var canSave: Bool {
        !trimmedName.isEmpty
    }

    private func save() {
        guard canSave else { return }
        state.rename(machine, to: trimmedName)
        dismiss()
    }
}

// MARK: - Auth URL

@MainActor
struct AuthURLDialog: View {
    @ObservedObject var state: AppState
    let dismiss: () -> Void

    var body: some View {
        if let result = state.authURL {
            if result.ok {
                DialogShell(
                    title: "新しいブラウザの認証 URL",
                    subtitle: "\(state.localMachine?.displayName ?? "この PC") の DSH に、新しいブラウザを認証します。URL を開くとそのブラウザは認証され、以降は通常の URL で使えます。",
                    width: 480
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !primaryURL(result).isEmpty {
                            urlBlock(label: "認証 URL", url: primaryURL(result))
                        }
                        if let local = result.localUrl,
                           !local.isEmpty,
                           local != primaryURL(result) {
                            urlBlock(label: "この PC のブラウザ用", url: local)
                        }
                        if primaryURL(result).isEmpty && (result.localUrl ?? "").isEmpty,
                           !result.message.isEmpty {
                            Text(result.message)
                                .font(Theme.body)
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("URL には認証情報が含まれます。DSH を再起動すると無効になります。必要な相手にだけ渡してください。")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                } footer: {
                    HStack(spacing: 8) {
                        if let pid = result.pid {
                            Text("PID \(pid)")
                                .font(Theme.mono(10.5))
                                .foregroundStyle(Theme.secondary)
                        }
                        Spacer(minLength: 8)
                        SmallButton("閉じる", kind: .secondary) { dismiss() }
                            .keyboardShortcut(.cancelAction)
                        SmallButton(
                            "ブラウザで開く",
                            kind: .primary,
                            symbol: "arrow.up.right.square",
                            enabled: !primaryURL(result).isEmpty
                        ) {
                            state.openURLString(primaryURL(result))
                        }
                    }
                }
            } else {
                DialogShell(title: "新しいブラウザの認証 URL", width: 440) {
                    Text(result.message)
                        .font(Theme.body)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } footer: {
                    HStack(spacing: 8) {
                        Spacer(minLength: 8)
                        SmallButton("閉じる", kind: .secondary) { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
        } else {
            EmptyView()
        }
    }

    private func primaryURL(_ result: AuthURLResult) -> String {
        if let external = result.externalUrl, !external.isEmpty { return external }
        if let url = result.url, !url.isEmpty { return url }
        return result.localUrl ?? ""
    }

    private func urlBlock(label: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
            Text(url)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                QuietButton("コピー", symbol: "doc.on.doc") { state.copy(url) }
                QuietButton("ブラウザで開く", symbol: "arrow.up.right.square") {
                    state.openURLString(url)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.buttonRadius)
                .fill(Theme.deep)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.buttonRadius)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}

// MARK: - PWA

@MainActor
struct PwaDialog: View {
    @ObservedObject var state: AppState
    let dismiss: () -> Void

    var body: some View {
        if let info = state.pwaInfo {
            DialogShell(
                title: info.installed ? "PWA" : "PWA が見つかりません",
                subtitle: "この PC の DSH を、ブラウザの Web アプリとして開きます。",
                width: 440
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(info.installed
                         ? "Web アプリはインストール済みです。"
                         : "この PC の DSH は、ブラウザの Web アプリ（PWA）としてインストールされていません。")
                        .font(Theme.body)
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if !info.installed {
                        Text("ブラウザで URL を開き、「アプリとしてインストール」（または「アプリをインストール」）で追加すると、ここから直接開けます。")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(info.url)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.buttonRadius)
                                .fill(Theme.deep)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Metrics.buttonRadius)
                                .strokeBorder(Theme.hairline, lineWidth: 1)
                        )
                    if let message = info.message, !message.isEmpty {
                        Text(message)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } footer: {
                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                    SmallButton("閉じる", kind: .secondary) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    if info.installed {
                        SmallButton(
                            "開く",
                            kind: .primary,
                            symbol: "square.and.arrow.up"
                        ) {
                            openInstalled()
                        }
                    } else {
                        SmallButton(
                            "ブラウザで開く",
                            kind: .primary,
                            symbol: "square.and.arrow.up"
                        ) {
                            state.openURLString(info.url)
                            dismiss()
                        }
                    }
                }
            }
        } else {
            EmptyView()
        }
    }

    /// `openPWA` always republishes `pwaInfo`, so clear it before and after the
    /// retry; only a real failure should bring the sheet back.
    private func openInstalled() {
        state.pwaInfo = nil
        dismiss()
        Task { @MainActor in
            await state.openPWA()
            if state.pwaInfo?.installed == true {
                state.pwaInfo = nil
            }
        }
    }
}

// MARK: - Error

/// A copyable error surface. Alerts cannot be selected, so errors use the same
/// calm sheet as the other dialogs.
@MainActor
struct ErrorDialog: View {
    @ObservedObject var state: AppState
    let dismiss: () -> Void

    var body: some View {
        if let message = state.errorMessage {
            DialogShell(title: "エラー", width: 440) {
                Text(message)
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } footer: {
                HStack(spacing: 8) {
                    QuietButton("コピー", symbol: "doc.on.doc") { state.copy(message) }
                    Spacer(minLength: 8)
                    SmallButton("閉じる", kind: .secondary) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        } else {
            EmptyView()
        }
    }
}
