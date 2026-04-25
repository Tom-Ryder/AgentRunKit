@testable import AgentCode
import Foundation
import Testing

struct CommandRunnerTests {
    @Test
    func deniedCommandDoesNotRun() async throws {
        let directory = try TemporaryDirectory()
        let workspace = try Workspace(root: directory.url)
        let runner = CommandRunner(allowedCommands: [])

        await #expect(throws: AgentCodeError.commandNotAllowed("swift --version")) {
            _ = try await runner.run(CommandInvocation(command: "swift", arguments: ["--version"]), in: workspace)
        }
    }

    @Test
    func allowlistedCommandRuns() async throws {
        let directory = try TemporaryDirectory()
        let workspace = try Workspace(root: directory.url)
        let runner = CommandRunner(allowedCommands: [.exact(command: "swift", arguments: ["--version"])])

        let result = try await runner.run(CommandInvocation(command: "swift", arguments: ["--version"]), in: workspace)

        #expect(result.exitStatus == 0)
        #expect(result.stdout.contains("Swift"))
    }

    @Test
    func allowlistedCommandFailureThrows() async throws {
        let directory = try TemporaryDirectory()
        let workspace = try Workspace(root: directory.url)
        let script = "printf failure >&2; exit 7"
        let runner = CommandRunner(allowedCommands: [.exact(command: "sh", arguments: ["-c", script])])

        await #expect(
            throws: AgentCodeError.processFailed(command: "sh -c \(script)", status: 7, output: "failure")
        ) {
            _ = try await runner.run(CommandInvocation(command: "sh", arguments: ["-c", script]), in: workspace)
        }
    }

    @Test
    func verboseCommandOutputDoesNotBlockProcessExit() async throws {
        let directory = try TemporaryDirectory()
        let workspace = try Workspace(root: directory.url)
        let script = "i=0; while [ $i -lt 20000 ]; do printf xxxxxxxxxx; i=$((i + 1)); done"
        let runner = CommandRunner(
            allowedCommands: [.exact(command: "sh", arguments: ["-c", script])],
            outputLimiter: OutputLimiter(maxCharacters: 80)
        )

        let result = try await runner.run(
            CommandInvocation(command: "sh", arguments: ["-c", script], timeoutSeconds: 5),
            in: workspace
        )

        #expect(result.exitStatus == 0)
        #expect(result.stdout.contains("[truncated"))
    }
}
