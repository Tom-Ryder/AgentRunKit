import AgentRunKit
import ArgumentParser
import Foundation

@main
struct AgentCodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-code",
        abstract: "An interactive terminal coding agent built with AgentRunKit."
    )

    @Option(help: "Workspace to edit. Defaults to the bundled DemoWorkspace.")
    var workspace: String?

    @Flag(help: "Use deterministic offline mode instead of an OpenAI-compatible provider.")
    var offline = false

    @Flag(help: "Run the terminal approval prompt smoke test without calling a model.")
    var approvalSmokeTest = false

    mutating func run() async throws {
        if approvalSmokeTest {
            try await runApprovalSmokeTest()
            return
        }
        let workspaceURL = try selectedWorkspaceURL()
        let provider = try ProviderConfiguration.load(forceOffline: offline)
        var app = try AgentCodeApp(workspaceURL: workspaceURL, provider: provider)
        try await app.run()
    }

    private func selectedWorkspaceURL() throws -> URL {
        if let workspace {
            return URL(
                fileURLWithPath: workspace,
                relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            )
            .standardizedFileURL
        }
        return Self.packageRoot.appendingPathComponent("DemoWorkspace")
    }

    private func runApprovalSmokeTest() async throws {
        let argumentData = try JSONEncoder().encode(
            EditFileParameters(
                path: "Sources/DemoWorkspace/Calculator.swift",
                oldString: "lhs + rhs",
                newString: "lhs - rhs",
                replaceAll: false
            )
        )
        guard let arguments = String(bytes: argumentData, encoding: .utf8) else {
            throw AgentCodeError.unreadableText("approval smoke arguments")
        }
        let data = try JSONEncoder().encode(
            SmokeApprovalRequest(
                toolCallId: "approval-smoke-test",
                toolName: "edit_file",
                arguments: arguments,
                toolDescription: "Replace an exact string in an existing file."
            )
        )
        let request = try JSONDecoder().decode(
            ToolApprovalRequest.self,
            from: data
        )
        let renderer = EventRenderer()
        await renderer.render(StreamEvent(kind: .toolCallStarted(name: "edit_file", id: request.toolCallId)))
        try? await Task.sleep(for: .milliseconds(150))
        await renderer.render(StreamEvent(kind: .toolApprovalRequested(request)))
        let decision = await ApprovalPrompt.resolve(request: request)
        await renderer.render(
            StreamEvent(kind: .toolApprovalResolved(toolCallId: request.toolCallId, decision: decision))
        )
        Terminal.writeLine("decision: \(decision.smokeTestDescription)")
    }

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct SmokeApprovalRequest: Codable {
    let toolCallId: String
    let toolName: String
    let arguments: String
    let toolDescription: String
}

private extension ToolApprovalDecision {
    var smokeTestDescription: String {
        switch self {
        case .approve:
            "approve"
        case .approveAlways:
            "approveAlways"
        case .approveWithModifiedArguments:
            "approveWithModifiedArguments"
        case .deny:
            "deny"
        }
    }
}
