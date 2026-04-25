@testable import AgentRunKit
import Foundation
import Testing

private struct EchoParams: Codable, SchemaProviding {
    let message: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

private struct EchoOutput: Codable {
    let echoed: String
}

private func makeEchoTool(name: String = "echo") throws -> Tool<EchoParams, EchoOutput, EmptyContext> {
    try Tool<EchoParams, EchoOutput, EmptyContext>(
        name: name,
        description: "Echoes",
        executor: { params, _ in EchoOutput(echoed: params.message) }
    )
}

struct AgentResumeMCPTests {
    @Test
    func resumeWithMissingMCPBindingThrowsMismatch() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let checkpointID = CheckpointID()
        let checkpoint = AgentCheckpoint(
            messages: [.user("Hi")],
            iteration: 1,
            tokenUsage: TokenUsage(input: 1, output: 1),
            sessionID: session, runID: RunID(), checkpointID: checkpointID,
            mcpToolBindings: [MCPToolBinding(serverName: "alpha", toolName: "search")]
        )
        try await backend.save(checkpoint)
        let echoTool = try makeEchoTool()
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: []), tools: [echoTool]
        )
        do {
            _ = try await agent.resume(
                from: checkpointID, checkpointer: backend, context: EmptyContext()
            )
            Issue.record("Expected mcpBindingMismatch")
        } catch let AgentCheckpointError.mcpBindingMismatch(missing) {
            #expect(missing.contains(MCPToolBinding(serverName: "alpha", toolName: "search")))
        } catch {
            Issue.record("Expected mcpBindingMismatch, got \(error)")
        }
    }

    @Test
    func resumeWithEmptyMCPBindingsAllowsResume() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let checkpointID = CheckpointID()
        let checkpoint = AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "ok"))],
            iteration: 1,
            tokenUsage: TokenUsage(input: 1, output: 1),
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        )
        try await backend.save(checkpoint)
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [
                [
                    .toolCallStart(index: 0, id: "call", name: "finish", kind: .function),
                    .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
                    .finished(usage: TokenUsage(input: 1, output: 1)),
                ],
            ]),
            tools: []
        )
        let stream = try await agent.resume(
            from: checkpointID, checkpointer: backend, context: EmptyContext()
        )
        var sawReplay = false
        var sawLiveFinish = false
        for try await event in stream {
            if case .iterationCompleted = event.kind, event.origin == .replayed(from: checkpointID) {
                sawReplay = true
            }
            if case let .finished(_, content, reason, _) = event.kind, event.origin == .live {
                sawLiveFinish = true
                #expect(content == "done")
                #expect(reason == .completed)
            }
        }
        #expect(sawReplay)
        #expect(sawLiveFinish)
    }
}
