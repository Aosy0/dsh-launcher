import AppKit
import SwiftUI

enum AppMain {
    /// `NSApplication.delegate` is weak. Keep the delegate (and therefore AppState and
    /// the window) alive for the lifetime of the process.
    @MainActor private static var retainedDelegate: AppDelegate?

    @MainActor
    static func run(configPath: String? = nil) {
        let application = NSApplication.shared
        let delegate = AppDelegate(configPath: configPath)
        retainedDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state: AppState
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var hosting: NSHostingController<MainView>?

    init(configPath: String?) {
        self.state = AppState(configPath: configPath)
        super.init()
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launch version=\(AppInfo.version) config=\(Paths.configPath.path)")
        state.onNeedsWindow = { [weak self] in
            self?.showWindow()
        }
        buildStatusItem()
        buildMainMenu()
        if let menu = statusItem?.menu {
            menuNeedsUpdate(menu)
        }
        showWindow()
        state.startPolling()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.write("terminate")
        state.stopPolling()
    }

    // MARK: Window

    func showWindow() {
        if window == nil {
            let view = MainView(state: state)
            let hosting = NSHostingController(rootView: view)
            let created = NSWindow(contentViewController: hosting)
            created.title = "DSH Launcher"
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.setContentSize(NSSize(width: 520, height: 620))
            created.minSize = NSSize(width: 460, height: 420)
            created.isReleasedWhenClosed = false
            created.titlebarAppearsTransparent = true
            created.appearance = NSAppearance(named: .darkAqua)
            created.backgroundColor = NSColor(
                calibratedRed: 0.078, green: 0.078, blue: 0.086, alpha: 1
            )
            created.center()
            self.window = created
            self.hosting = hosting
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            Log.write("window shown visible=\(window.isVisible) frame=\(NSStringFromRect(window.frame))")
        }
    }

    // MARK: Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "server.rack",
                accessibilityDescription: "DSH Launcher"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "DSH Launcher"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
        Log.write("status item created")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: state.aggregateText, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let sorted = state.machines.sorted { lhs, rhs in
            let left = state.status(for: lhs).state == .running
            let right = state.status(for: rhs).state == .running
            if left != right { return left }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        for machine in sorted {
            menu.addItem(machineMenuItem(machine))
        }

        menu.addItem(.separator())
        menu.addItem(menuItem("PWA を開く", #selector(openPWA), key: ""))
        menu.addItem(menuItem("認証 URL を発行…", #selector(issueAuthURL), key: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("ウィンドウを開く", #selector(openWindow), key: "0"))
        menu.addItem(menuItem("一覧を更新", #selector(refreshNow), key: "r"))
        menu.addItem(.separator())
        menu.addItem(menuItem("DSH Launcher を終了", #selector(quit), key: "q"))
        Log.write("menu built items=\(menu.items.count)")
    }

    private func machineMenuItem(_ machine: Machine) -> NSMenuItem {
        let status = state.status(for: machine)
        let item = NSMenuItem(
            title: "\(machine.displayName)  —  \(status.stateText)",
            action: nil,
            keyEquivalent: ""
        )
        item.representedObject = machine.id
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let stateItem = NSMenuItem(title: status.stateText, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        submenu.addItem(stateItem)
        if let pid = status.pid {
            let facts = NSMenuItem(title: "PID \(pid) · port \(machine.port)", action: nil, keyEquivalent: "")
            facts.isEnabled = false
            submenu.addItem(facts)
        }
        submenu.addItem(.separator())

        let busy = state.busy[machine.id]
        let open = menuItem("ブラウザで開く", #selector(openMachine), key: "", machine: machine)
        open.isEnabled = busy == nil
        submenu.addItem(open)

        if status.state == .running {
            let restart = menuItem("再起動…", #selector(restartMachine), key: "", machine: machine)
            restart.isEnabled = busy == nil
            submenu.addItem(restart)
            let stop = menuItem("停止…", #selector(stopMachine), key: "", machine: machine)
            stop.isEnabled = busy == nil
            submenu.addItem(stop)
        } else {
            let start = menuItem("起動…", #selector(startMachine), key: "", machine: machine)
            start.isEnabled = busy == nil
            submenu.addItem(start)
        }
        if let busy {
            let item = NSMenuItem(
                title: "\(busy.label) \(busy.elapsedText)",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        let logs = menuItem("ログ…", #selector(showLogs), key: "", machine: machine)
        logs.isEnabled = busy == nil
        submenu.addItem(logs)
        submenu.addItem(menuItem("詳細を開く", #selector(showDetails), key: "", machine: machine))

        item.submenu = submenu
        return item
    }

    private func menuItem(
        _ title: String,
        _ selector: Selector,
        key: String,
        machine: Machine? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.representedObject = machine?.id
        return item
    }

    private func machine(from sender: NSMenuItem) -> Machine? {
        guard let id = sender.representedObject as? String else { return nil }
        return state.machine(id: id)
    }

    // MARK: Menu actions

    @objc private func openMachine(_ sender: NSMenuItem) {
        guard let machine = machine(from: sender) else { return }
        state.open(machine)
    }

    @objc private func startMachine(_ sender: NSMenuItem) {
        guard let machine = machine(from: sender) else { return }
        state.request(.start, for: machine)
    }

    @objc private func stopMachine(_ sender: NSMenuItem) {
        guard let machine = machine(from: sender) else { return }
        state.request(.stop, for: machine)
    }

    @objc private func restartMachine(_ sender: NSMenuItem) {
        guard let machine = machine(from: sender) else { return }
        state.request(.restart, for: machine)
    }

    @objc private func showLogs(_ sender: NSMenuItem) {
        guard let machine = machine(from: sender) else { return }
        state.showLogs(machine)
    }

    @objc private func showDetails(_ sender: NSMenuItem) {
        guard let machine = machine(from: sender) else { return }
        state.selectedId = machine.id
        showWindow()
    }

    @objc private func openPWA() {
        Task { @MainActor in
            await state.openPWA()
            showWindow()
        }
    }

    @objc private func issueAuthURL() {
        Task { @MainActor in
            await state.prepareAuthURL()
            showWindow()
        }
    }

    @objc private func openWindow() {
        showWindow()
    }

    @objc private func refreshNow() {
        Task { @MainActor in await state.refreshAll(force: true) }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "DSH Launcher \(AppInfo.version)"
        alert.informativeText = """
        DeepSeek Harness (dsh) を起動・停止・状態確認する非公式ランチャーです。
        DeepSeek 公式の製品ではありません（MIT / 無保証）。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: Main menu

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "DSH Launcher について", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "DSH Launcher を隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "ほかを隠す", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        appMenu.items.last?.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "DSH Launcher を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "すべて選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "すべてを手前に移動", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        let machineItem = NSMenuItem()
        main.addItem(machineItem)
        let machineMenu = NSMenu(title: "マシン")
        machineMenu.addItem(withTitle: "一覧を更新", action: #selector(refreshNow), keyEquivalent: "r")
        machineMenu.addItem(withTitle: "ウィンドウを開く", action: #selector(openWindow), keyEquivalent: "0")
        machineMenu.addItem(.separator())
        machineMenu.addItem(withTitle: "PWA を開く", action: #selector(openPWA), keyEquivalent: "")
        machineMenu.addItem(withTitle: "認証 URL を発行…", action: #selector(issueAuthURL), keyEquivalent: "")
        for item in machineMenu.items { item.target = self }
        machineItem.submenu = machineMenu

        NSApp.mainMenu = main
    }
}
