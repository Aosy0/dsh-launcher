import CryptoKit
import Foundation

/// Opens this Mac's DSH as an installed web app (PWA) in whichever Chromium-based browser has it.
///
/// macOS stores installed web apps as `.app` bundles the browser creates under
/// `~/Applications`: `Chrome Apps.localized`, `Brave Browser Apps.localized`,
/// `Vivaldi Apps.localized`, `Microsoft Edge Apps.localized`, plus the older `Chrome Apps` and
/// `Edge Apps`. Each bundle's `Contents/Info.plist` records the app id
/// (`CrAppModeShortcutID`), the start URL (`CrAppModeShortcutURL`) and the display name, so
/// detection reads that plist instead of any browser-internal database. Launching is the
/// ordinary `open -a <bundle>`; nothing is ever installed from here.
enum BrowserApp {
    // MARK: - Browser catalogue

    private struct BrowserDefinition {
        var label: String
        var bundleIDs: [String]
        var applicationNames: [String]
    }

    private struct ShortcutDirectory {
        var browser: String
        /// Directory name under `~/Applications`.
        var name: String
    }

    private static let definitions: [BrowserDefinition] = [
        BrowserDefinition(
            label: "Chrome",
            bundleIDs: ["com.google.Chrome"],
            applicationNames: ["Google Chrome"]
        ),
        BrowserDefinition(
            label: "Brave",
            bundleIDs: ["com.brave.Browser"],
            applicationNames: ["Brave Browser"]
        ),
        BrowserDefinition(
            label: "Vivaldi",
            bundleIDs: ["com.vivaldi.Vivaldi"],
            applicationNames: ["Vivaldi"]
        ),
        BrowserDefinition(
            label: "Edge",
            bundleIDs: ["com.microsoft.edgemac"],
            applicationNames: ["Microsoft Edge"]
        )
    ]

    /// Scanned in this order; only directories that exist are used.
    private static let shortcutDirectories: [ShortcutDirectory] = [
        ShortcutDirectory(browser: "Chrome", name: "Chrome Apps.localized"),
        ShortcutDirectory(browser: "Brave", name: "Brave Browser Apps.localized"),
        ShortcutDirectory(browser: "Vivaldi", name: "Vivaldi Apps.localized"),
        ShortcutDirectory(browser: "Edge", name: "Microsoft Edge Apps.localized"),
        ShortcutDirectory(browser: "Chrome", name: "Chrome Apps"),
        ShortcutDirectory(browser: "Edge", name: "Edge Apps")
    ]

    // MARK: - Public API

    /// The installed web app for this machine's URL, with a hint when there is none.
    static func info(for machine: Machine) -> PwaInfo {
        let browserList = browsers()
        let target = machine.targetURLString

        if let app = find(for: machine) {
            return PwaInfo(
                installed: true,
                url: target,
                appId: app.appID ?? appIDCandidates(for: candidateURLs(for: machine)).first,
                appPath: app.path,
                bundleId: app.bundleID,
                browser: app.browser,
                appName: app.name,
                message: nil,
                browsers: browserList
            )
        }

        return PwaInfo(
            installed: false,
            url: target,
            appId: nil,
            appPath: nil,
            bundleId: nil,
            browser: nil,
            appName: nil,
            message: browserList.isEmpty
                ? "PWA が見つかりません。Web アプリに対応したブラウザ（Chromium 系）が見つかりません。"
                : "PWA が見つかりません。ブラウザで開きます",
            browsers: browserList
        )
    }

    /// Opens the installed web app, or falls back to the default browser with install guidance.
    static func open(_ machine: Machine) async -> PwaInfo {
        let current = info(for: machine)

        if current.installed, let appPath = current.appPath {
            let result = await Shell.run("/usr/bin/open", ["-a", appPath])
            var opened = current
            opened.message = result.ok ? "PWA を開きました" : openFailure(result, subject: "PWA")
            return opened
        }

        // No installed Web App: open the URL in the default browser and explain the install
        // step instead of installing anything ourselves.
        let result = await Shell.run("/usr/bin/open", [current.url])
        var opened = current
        if result.ok {
            opened.message = current.browsers.isEmpty
                ? "PWA が見つかりません。ブラウザで開きました。Web アプリに対応したブラウザ（Chromium 系）を入れると PWA として開けます。"
                : "PWA が見つかりません。ブラウザで開きました。ブラウザのメニューの「アプリとしてインストール」で追加すると、次回から PWA で開けます。"
        } else {
            opened.message = openFailure(result, subject: "ブラウザ")
        }
        return opened
    }

    /// Chromium-based browsers found on this Mac, with the Web App directories they own.
    static func browsers() -> [BrowserInfo] {
        var result: [BrowserInfo] = []
        for definition in definitions {
            let appPath = applicationPath(for: definition)
            let directories = shortcutDirectories
                .filter { $0.browser == definition.label }
                .map { userApplicationsDirectory + "/" + $0.name }
                .filter { isDirectory($0) }
            // A browser counts as present when its app or one of its shortcut directories exists.
            guard appPath != nil || !directories.isEmpty else { continue }

            result.append(
                BrowserInfo(
                    name: definition.label,
                    bundleId: appPath.flatMap { infoPlistValue($0, "CFBundleIdentifier") }
                        ?? definition.bundleIDs.first,
                    appPath: appPath,
                    pwaDirs: directories
                )
            )
        }
        return result
    }

    // MARK: - Detection

    private struct InstalledWebApp {
        var path: String
        var browser: String
        var appID: String?
        var shortcutURL: String?
        var bundleID: String?
        var name: String?
    }

    private static func find(for machine: Machine) -> InstalledWebApp? {
        let apps = installedWebApps()
        guard !apps.isEmpty else { return nil }

        let urls = candidateURLs(for: machine)
        guard !urls.isEmpty else { return nil }

        // The shortcut records the start URL verbatim, so compare that first. The app id is a
        // hash of the manifest id, one step further removed from what the install recorded.
        for app in apps {
            guard let shortcut = app.shortcutURL,
                  let canonical = canonicalPageURL(shortcut) else { continue }
            if urls.contains(canonical) { return app }
        }

        let ids = Set(appIDCandidates(for: urls))
        for app in apps {
            guard let appID = app.appID?.lowercased() else { continue }
            if ids.contains(appID) { return app }
        }
        return nil
    }

    /// Every `.app` in the browser-owned shortcut directories, in scan order.
    private static func installedWebApps() -> [InstalledWebApp] {
        let fileManager = FileManager.default
        var apps: [InstalledWebApp] = []

        for shortcut in shortcutDirectories {
            let directory = userApplicationsDirectory + "/" + shortcut.name
            guard isDirectory(directory),
                  let entries = try? fileManager.contentsOfDirectory(atPath: directory) else {
                continue
            }

            for entry in entries.sorted() where entry.lowercased().hasSuffix(".app") {
                let path = directory + "/" + entry
                guard isDirectory(path), let plist = readInfoPlist(path) else { continue }

                let appID = string(plist["CrAppModeShortcutID"])
                let shortcutURL = string(plist["CrAppModeShortcutURL"])
                // A bundle without either identifying field is not a Web App shortcut.
                guard appID != nil || shortcutURL != nil else { continue }

                apps.append(
                    InstalledWebApp(
                        path: path,
                        browser: shortcut.browser,
                        appID: appID,
                        shortcutURL: shortcutURL,
                        bundleID: string(plist["CFBundleIdentifier"]),
                        name: string(plist["CrAppModeShortcutName"])
                            ?? string(plist["CFBundleName"])
                    )
                )
            }
        }
        return apps
    }

    /// Addresses the web app could have been installed from (origin + directory spelling).
    private static func candidateURLs(for machine: Machine) -> [String] {
        let configured = machine.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An ssh machine without url falls back to 127.0.0.1 in targetURLString: never resolve a
        // remote machine to this Mac's app.
        if machine.kind != .local && configured.isEmpty { return [] }

        var result: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            guard let canonical = canonicalPageURL(raw), seen.insert(canonical).inserted else {
                return
            }
            result.append(canonical)
        }

        add(machine.targetURLString)
        if machine.kind == .local {
            // The local DSH may have been installed from either loopback spelling.
            add("http://127.0.0.1:\(machine.port)/")
            add("http://localhost:\(machine.port)/")
        }
        return result
    }

    /// Origin + directory, always with a trailing slash, without query or fragment.
    ///
    /// dsh serves `start_url: "./"` and no manifest `id`, so the manifest id — and therefore the
    /// Web App ID — is the directory the manifest is served from.
    private static func canonicalPageURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }

        // Keep the percent-encoded path: it is part of the manifest id that is hashed below.
        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        if !path.hasSuffix("/") { path += "/" }

        var portText = ""
        if let port = components.port, port > 0,
           !(scheme == "http" && port == 80),
           !(scheme == "https" && port == 443) {
            portText = ":\(port)"
        }

        let hostText = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(hostText)\(portText)\(path)"
    }

    // MARK: - App id

    /// The a–p alphabet the app id is written in: one character per hex nibble.
    private static let appIDAlphabet = Array("abcdefghijklmnop")

    /// Chromium's Web App ID: hash the manifest id with SHA-256 twice, then map the first 16
    /// bytes onto 32 characters of the a–p alphabet (one character per nibble). The second hash
    /// is historical but load-bearing — see `components/webapps/common/web_app_id.h`.
    static func generateAppID(manifestID: String) -> String {
        let inner = SHA256.hash(data: Data(manifestID.utf8))
        let digest = Array(SHA256.hash(data: Data(inner)))

        var characters: [Character] = []
        characters.reserveCapacity(32)
        for index in 0..<16 {
            let byte = Int(digest[index])
            characters.append(appIDAlphabet[byte >> 4])
            characters.append(appIDAlphabet[byte & 0x0F])
        }
        return String(characters)
    }

    private static func appIDCandidates(for urls: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for url in urls {
            for manifestID in manifestIDs(for: url) {
                let appID = generateAppID(manifestID: manifestID)
                if seen.insert(appID).inserted { result.append(appID) }
            }
        }
        return result
    }

    /// The directory form (dsh's `start_url: "./"`), plus the origin root as a fallback for
    /// installs made from a bare origin.
    private static func manifestIDs(for canonicalURL: String) -> [String] {
        var result = [canonicalURL]
        if var components = URLComponents(string: canonicalURL) {
            components.path = "/"
            if let root = components.url?.absoluteString, root != canonicalURL {
                result.append(root)
            }
        }
        return result
    }

    // MARK: - Browser applications

    private static func applicationPath(for definition: BrowserDefinition) -> String? {
        for name in definition.applicationNames {
            for directory in [systemApplicationsDirectory, userApplicationsDirectory] {
                let path = directory + "/" + name + ".app"
                if isDirectory(path) { return path }
            }
        }
        return nil
    }

    // MARK: - Files

    private static func readInfoPlist(_ appPath: String) -> [String: Any]? {
        let path = appPath + "/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) else {
            return nil
        }
        return plist as? [String: Any]
    }

    private static func infoPlistValue(_ appPath: String, _ key: String) -> String? {
        guard let plist = readInfoPlist(appPath) else { return nil }
        return string(plist[key])
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    private static func openFailure(_ result: ShellResult, subject: String) -> String {
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return "\(subject)を開けませんでした（open が終了コード \(result.exit) で失敗しました）"
        }
        return "\(subject)を開けませんでした: \(detail)"
    }

    private static var userApplicationsDirectory: String {
        Paths.home.appendingPathComponent("Applications").path
    }

    private static let systemApplicationsDirectory = "/Applications"
}
