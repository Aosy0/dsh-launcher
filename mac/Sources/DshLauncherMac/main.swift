import Darwin
import Foundation

private func optionValue(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

let arguments = Array(CommandLine.arguments.dropFirst())
let configPath = optionValue("--config", in: arguments)

if arguments.isEmpty || arguments.first == "gui" {
    // Start AppKit from a synchronous top-level context. Running NSApplication.run()
    // inside a MainActor task would block the main-actor executor forever, and
    // MainActor tasks created by AppState (polling, operations) would never run.
    MainActor.assumeIsolated {
        AppMain.run(configPath: configPath)
    }
    exit(0)
}

if arguments.contains("--version") || arguments.contains("-V") {
    print(AppInfo.version)
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") || arguments.first == "help" {
    CLI.printHelp()
    exit(0)
}

if arguments.first == "snapshot" {
    let output = arguments.count > 1 ? arguments[1] : "dshl-ui.png"
    var code: Int32 = 1
    MainActor.assumeIsolated {
        code = CLI.renderSnapshot(output: output, configPath: configPath)
    }
    exit(code)
}

final class ExitBox: @unchecked Sendable {
    var code: Int32 = 0
}

let box = ExitBox()
let semaphore = DispatchSemaphore(value: 0)
Task.detached {
    box.code = await CLI.run(arguments)
    semaphore.signal()
}
semaphore.wait()
exit(box.code)
