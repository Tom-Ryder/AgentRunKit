import Foundation

struct CommandInvocation: Codable, Equatable {
    let command: String
    let arguments: [String]
    let timeoutSeconds: Int?

    init(command: String, arguments: [String] = [], timeoutSeconds: Int? = nil) {
        self.command = command
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
    }
}

struct CommandResult: Codable, Equatable {
    let command: String
    let exitStatus: Int32
    let stdout: String
    let stderr: String

    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct CommandRunner {
    let allowedCommands: Set<AllowedCommand>
    let outputLimiter: OutputLimiter

    init(
        allowedCommands: Set<AllowedCommand> = AllowedCommand.defaultVerificationCommands,
        outputLimiter: OutputLimiter = OutputLimiter()
    ) {
        self.allowedCommands = allowedCommands
        self.outputLimiter = outputLimiter
    }

    func run(
        _ invocation: CommandInvocation,
        in workspace: Workspace,
        input: String? = nil
    ) async throws -> CommandResult {
        guard allowedCommands.contains(where: { $0.matches(invocation) }) else {
            throw AgentCodeError.commandNotAllowed(invocation.displayString)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [invocation.command] + invocation.arguments
        process.currentDirectoryURL = workspace.root

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if input != nil {
            process.standardInput = stdinPipe
        }

        try process.run()
        async let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        async let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if let input {
            stdinPipe.fileHandleForWriting.write(Data(input.utf8))
            try stdinPipe.fileHandleForWriting.close()
        }

        let timeout = TimeInterval(invocation.timeoutSeconds ?? 60)
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                _ = await (stdoutData, stderrData)
                throw AgentCodeError.commandTimedOut(invocation.displayString)
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let stdout = await String(
            bytes: stdoutData,
            encoding: .utf8
        ) ?? ""
        let stderr = await String(
            bytes: stderrData,
            encoding: .utf8
        ) ?? ""
        let result = CommandResult(
            command: invocation.displayString,
            exitStatus: process.terminationStatus,
            stdout: outputLimiter.truncate(stdout),
            stderr: outputLimiter.truncate(stderr)
        )
        if process.terminationStatus != 0 {
            throw AgentCodeError.processFailed(
                command: invocation.displayString,
                status: process.terminationStatus,
                output: result.combinedOutput
            )
        }
        return result
    }
}

enum AllowedCommand: Hashable {
    case exact(command: String, arguments: [String])
    case prefix(command: String, arguments: [String])
    case gitDiff
    case gitStatus

    static let defaultVerificationCommands: Set<AllowedCommand> = [
        .exact(command: "swift", arguments: ["test"]),
        .exact(command: "swift", arguments: ["build"]),
        .exact(command: "npm", arguments: ["test"]),
        .exact(command: "npm", arguments: ["run", "test"]),
        .exact(command: "python", arguments: ["-m", "pytest"]),
        .exact(command: "python3", arguments: ["-m", "pytest"]),
        .gitDiff,
        .gitStatus
    ]

    func matches(_ invocation: CommandInvocation) -> Bool {
        switch self {
        case let .exact(command, arguments):
            invocation.command == command && invocation.arguments == arguments
        case let .prefix(command, arguments):
            invocation.command == command && invocation.arguments.starts(with: arguments)
        case .gitDiff:
            invocation.command == "git" && invocation.arguments == ["diff", "--"]
        case .gitStatus:
            invocation.command == "git" && invocation.arguments == ["status", "--short", "--branch"]
        }
    }

    var displayString: String {
        switch self {
        case let .exact(command, arguments), let .prefix(command, arguments):
            ([command] + arguments).joined(separator: " ")
        case .gitDiff:
            "git diff --"
        case .gitStatus:
            "git status --short --branch"
        }
    }
}

extension CommandInvocation {
    var displayString: String {
        ([command] + arguments).joined(separator: " ")
    }
}
