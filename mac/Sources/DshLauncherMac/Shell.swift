import Foundation

struct ShellResult: Sendable {
    var exit: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool

    var ok: Bool { exit == 0 && !timedOut }

    var combined: String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if err.isEmpty { return stdout }
        return stdout + (stdout.hasSuffix("\n") ? "" : "\n") + err
    }
}

enum Shell {
    /// Run a process and collect stdout/stderr. Never throws; failures are in the result.
    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: TimeInterval = 20,
        environment: [String: String]? = nil,
        stdin: String? = nil
    ) async -> ShellResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: runSync(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout,
                        environment: environment,
                        stdin: stdin
                    )
                )
            }
        }
    }

    /// Run `/bin/sh -c <command>`.
    static func sh(
        _ command: String,
        timeout: TimeInterval = 20,
        environment: [String: String]? = nil
    ) async -> ShellResult {
        await run("/bin/sh", ["-c", command], timeout: timeout, environment: environment)
    }

    /// Synchronous variant for tiny calls from model helpers (lsof, scutil).
    static func runSync(
        executable: String,
        arguments: [String] = [],
        timeout: TimeInterval = 20,
        environment: [String: String]? = nil,
        stdin: String? = nil
    ) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        if let environment {
            for (key, value) in environment { env[key] = value }
        }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        if stdin != nil {
            process.standardInput = Pipe()
        }

        do {
            try process.run()
        } catch {
            return ShellResult(
                exit: -1,
                stdout: "",
                stderr: "cannot start \(executable): \(error.localizedDescription)",
                timedOut: false
            )
        }

        if let stdin, let pipe = process.standardInput as? Pipe {
            pipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? pipe.fileHandleForWriting.close()
        }

        final class DataBox: @unchecked Sendable {
            var data = Data()
        }
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if timedOut {
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        group.wait()

        return ShellResult(
            exit: process.terminationStatus,
            stdout: String(data: outBox.data, encoding: .utf8) ?? "",
            stderr: String(data: errBox.data, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    /// Resolve an executable with the user's login shell environment.
    /// GUI apps and launchd jobs do not inherit the shell PATH, so this is used
    /// when building start scripts.
    static func loginWhich(_ name: String) -> String? {
        let result = runSync(
            executable: "/bin/zsh",
            arguments: ["-lic", "command -v \(name)"],
            timeout: 8
        )
        let lines = result.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return lines.last(where: { $0.hasPrefix("/") })
    }
}
