import AgentRunKit
import ArgumentParser
import Foundation

struct AgentCodeApp {
    private let workspace: Workspace
    private let provider: ProviderConfiguration
    private let context: CodingContext
    private let chat: Chat<CodingContext>
    @MainActor private let eventRenderer = EventRenderer()
    private var history: [ChatMessage] = []
    private var transcript: [StreamEvent] = []

    init(workspaceURL: URL, provider: ProviderConfiguration) throws {
        let workspace = try Workspace(root: workspaceURL)
        let commandRunner = CommandRunner()
        let context = CodingContext(
            workspace: workspace,
            commandRunner: commandRunner
        )
        self.workspace = workspace
        self.provider = provider
        self.context = context
        chat = try Chat(
            client: provider.client,
            tools: CodingTools.makeTools(),
            systemPrompt: Self.systemPrompt,
            maxToolRounds: 12,
            toolTimeout: .seconds(45),
            maxMessages: 80,
            maxToolResultCharacters: 40000,
            approvalPolicy: .tools(["edit_file", "multi_edit", "write_file", "run_command"])
        )
    }

    mutating func run() async throws {
        Terminal.printBanner(workspace: workspace.root.path, provider: provider.description)
        if provider.offline {
            Terminal.writeLine("Offline mode is active. Set OPENAI_API_KEY for the full coding-agent experience.")
        }
        while true {
            Terminal.write(Terminal.promptPrefix(), terminator: "")
            guard let input = readLine() else { break }
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if try await handleSlashCommand(trimmed) {
                continue
            }
            try await runAgentTurn(prompt: trimmed)
        }
    }

    private mutating func runAgentTurn(prompt: String) async throws {
        let stream = chat.stream(
            prompt,
            history: history,
            context: context,
            approvalHandler: makeApprovalHandler()
        )

        do {
            for try await event in stream {
                transcript.append(event)
                await eventRenderer.render(event)
                if case let .finished(_, _, _, finishedHistory) = event.kind {
                    history = finishedHistory
                }
            }
            await eventRenderer.finishSpinner()
            Terminal.writeLine("")
        } catch {
            await eventRenderer.finishSpinner()
            Terminal.writeLine("")
            Terminal.writeLine("Error: \(error.localizedDescription)")
        }
    }

    private func makeApprovalHandler() -> ToolApprovalHandler {
        { request in
            await ApprovalPrompt.resolve(request: request)
        }
    }

    private mutating func handleSlashCommand(_ input: String) async throws -> Bool {
        guard input.hasPrefix("/") else { return false }
        switch input {
        case "/help":
            Terminal.section("Help")
            Terminal.writeLine(SlashCommandHelp.text)
        case "/status":
            Terminal.section("Status")
            Terminal.writeKeyValue("Workspace", workspace.root.path)
            Terminal.writeKeyValue("Provider", provider.description)
            Terminal.writeKeyValue("History", "\(history.count) messages")
        case "/diff":
            Terminal.section("Diff")
            let diff = try await workspace.currentDiff()
            Terminal.writeLine(diff.isEmpty ? "No git diff." : diff)
        case "/model":
            Terminal.section("Model")
            Terminal.writeLine(provider.description)
        case "/permissions":
            Terminal.section("Permissions")
            Terminal.writeLine(PermissionsDescription.text)
        case "/reset":
            history = []
            transcript = []
            Terminal.writeLine("\(Terminal.pill("reset", style: .green)) Session cleared.")
        case "/transcript":
            let url = workspace.root.appendingPathComponent(".agent-code-transcript.json")
            let encoder = StreamEventJSONCodec.makeEncoder()
            let data = try encoder.encode(transcript)
            try data.write(to: url, options: .atomic)
            Terminal.writeLine("\(Terminal.pill("saved", style: .green)) \(url.path)")
        case "/exit", "/quit":
            throw ExitCode.success
        default:
            Terminal.writeLine("Unknown command. Type /help.")
        }
        return true
    }

    private static let systemPrompt = """
    You are AgentCode, an interactive coding agent running inside a local workspace.
    Inspect the project before editing. Use workspace_status, list_files, glob, grep, read_file, and git_diff.
    Never request paths outside the workspace, secrets, private keys, .env files, or hidden credential folders.
    Edit like a terminal coding agent: use edit_file for exact old-string/new-string replacements, multi_edit for
    several replacements in one file, and write_file only when creating or intentionally replacing a whole file.
    Prefer small exact edits over whole-file writes. Read a file immediately before editing it.
    After edits, run an allowlisted verification command such as swift test or swift build when the project supports it.
    When the task is complete, respond normally without calling another tool.
    Keep final responses concise: summarize what changed, verification results, and any remaining issue.
    """
}
