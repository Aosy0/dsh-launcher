import Foundation

struct DshInstall: Sendable {
    /// Full argv prefix, e.g. ["/Users/x/.npm-global/bin/dsh"] or [node, bin.js].
    var command: [String]
    /// Directory that must be prepended to PATH (node / npm global bin).
    var pathEntries: [String]
    var nodeVersion: String?

    var displayPath: String { command.first ?? "dsh" }
}

/// Finds the user's dsh installation without assuming the GUI process PATH.
/// The Windows launcher reads the registry; on macOS the equivalent facts are
/// the npm global directory, nvm, Homebrew, and the login shell.
enum DshResolver {
    static func find() -> DshInstall? {
        let home = Paths.home.path
        let fm = FileManager.default

        var pathEntries: [String] = []
        var node: (path: String, version: String)?
        if let best = bestNode() {
            node = best
            pathEntries.append((best.path as NSString).deletingLastPathComponent)
        }

        let dshCandidates = [
            "\(home)/.npm-global/bin/dsh",
            "\(home)/.dsh/npm-global/bin/dsh",
            "\(home)/.local/bin/dsh",
            "/opt/homebrew/bin/dsh",
            "/usr/local/bin/dsh"
        ]

        var executables = dshCandidates.filter { fm.isExecutableFile(atPath: $0) }
        // nvm-installed dsh (rare, but keep the same search as the remote helper).
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmRoot) {
            for version in versions.sorted(by: versionDescending) {
                let candidate = "\(nvmRoot)/\(version)/bin/dsh"
                if fm.isExecutableFile(atPath: candidate) {
                    executables.append(candidate)
                }
            }
        }
        if let login = Shell.loginWhich("dsh"),
           fm.isExecutableFile(atPath: login),
           !executables.contains(login) {
            executables.append(login)
        }

        if let executable = executables.first {
            pathEntries.append((executable as NSString).deletingLastPathComponent)
            return DshInstall(
                command: [executable],
                pathEntries: unique(pathEntries),
                nodeVersion: node?.version
            )
        }

        // No shim: use lib/bin.js with a supported node directly.
        let binJSCandidates = [
            "\(home)/.npm-global/lib/node_modules/@deepseek-ai/dsh/lib/bin.js",
            "\(home)/.dsh/npm-global/lib/node_modules/@deepseek-ai/dsh/lib/bin.js",
            "/opt/homebrew/lib/node_modules/@deepseek-ai/dsh/lib/bin.js",
            "/usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"
        ]
        if let binJS = binJSCandidates.first(where: { fm.fileExists(atPath: $0) }) {
            if let node {
                pathEntries.append((node.path as NSString).deletingLastPathComponent)
                return DshInstall(
                    command: [node.path, binJS],
                    pathEntries: unique(pathEntries),
                    nodeVersion: node.version
                )
            }
            if let loginNode = Shell.loginWhich("node") {
                pathEntries.append((loginNode as NSString).deletingLastPathComponent)
                return DshInstall(
                    command: [loginNode, binJS],
                    pathEntries: unique(pathEntries),
                    nodeVersion: nodeVersion(of: loginNode)
                )
            }
        }
        return nil
    }

    /// Prefer nvm 24.x, then Homebrew/system node if it is 24.9+.
    static func bestNode() -> (path: String, version: String)? {
        let home = Paths.home.path
        let fm = FileManager.default
        var candidates: [String] = []
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmRoot) {
            for version in versions.sorted(by: versionDescending) {
                candidates.append("\(nvmRoot)/\(version)/bin/node")
            }
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "\(home)/.dsh/runtime/node/bin/node",
            "\(home)/.local/bin/node"
        ])
        if let login = Shell.loginWhich("node"), !candidates.contains(login) {
            candidates.append(login)
        }

        var fallback: (path: String, version: String)?
        for path in candidates where fm.isExecutableFile(atPath: path) {
            guard let version = nodeVersion(of: path) else { continue }
            if isNodeSupported(version) {
                return (path, version)
            }
            if fallback == nil {
                fallback = (path, version)
            }
        }
        return fallback
    }

    static func nodeVersion(of path: String) -> String? {
        let result = Shell.runSync(executable: path, arguments: ["-v"], timeout: 5)
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func isNodeSupported(_ version: String) -> Bool {
        let text = version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return parts[0] > 24 || (parts[0] == 24 && parts[1] >= 9)
    }

    static func versionDescending(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return lhs > rhs
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }
}
