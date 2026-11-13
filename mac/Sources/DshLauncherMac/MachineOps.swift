import Foundation

/// One entry point for machine status and lifecycle, shared by the CLI and the UI.
enum MachineOps {
    static func displayCommand(_ machine: Machine, verb: String) -> String {
        if machine.isLocal {
            return LocalMachine.commandLine(machine)
        }
        return RemoteMachine.actionCommand(machine, verb)
    }

    static func status(_ machine: Machine) async -> MachineStatus {
        var status: MachineStatus
        if machine.isLocal {
            status = await LocalMachine.status(machine)
        } else {
            status = await RemoteMachine.status(machine)
        }
        status.command = displayCommand(machine, verb: machine.isLocal ? "restart" : "status")
        return status
    }

    static func action(_ machine: Machine, _ verb: String) async -> (Bool, String) {
        if machine.isLocal {
            switch verb {
            case "start": return await LocalMachine.start(machine)
            case "stop": return await LocalMachine.stop(machine)
            default: return await LocalMachine.restart(machine)
            }
        }
        return await RemoteMachine.action(machine, verb)
    }

    static func deploy(_ machine: Machine) async -> (Bool, String) {
        if machine.isLocal { return (true, "local machine needs no helper") }
        return await RemoteMachine.deploy(machine)
    }

    static func setup(
        _ machine: Machine,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> SetupOutcome {
        if machine.isLocal {
            return SetupOutcome(
                ok: false,
                message: "local machine needs no setup",
                steps: [],
                transcript: []
            )
        }
        return await RemoteMachine.setup(machine, progress: progress)
    }

    static func tail(_ machine: Machine, lines: Int) async -> [String] {
        if machine.isLocal {
            return LocalMachine.tail(machine, lines: lines)
        }
        return await RemoteMachine.tail(machine, lines: lines)
    }
}
