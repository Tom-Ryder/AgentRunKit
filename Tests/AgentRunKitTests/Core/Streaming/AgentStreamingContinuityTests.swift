@testable import AgentRunKit
import Testing

struct StreamingContinuityTests {
    @Test
    func finalizedContinuityPersistsInStreamedHistory() async throws {
        let echoTool = try Tool<ContinuityEchoParams, ContinuityEchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in ContinuityEchoOutput(echoed: "Echo: \(params.message)") }
        )
        let continuity = AssistantContinuity(
            substrate: .responses,
            payload: .object(["response_id": .string("resp_123")])
        )
        let firstIteration: [RunStreamElement] = [
            .delta(.content("Looking that up")),
            .delta(.toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function)),
            .delta(.toolCallDelta(index: 0, arguments: #"{"message": "hello"}"#)),
            .finalizedContinuity(continuity),
            .delta(.finished(usage: nil)),
        ]
        let secondIteration: [RunStreamElement] = [
            .delta(.toolCallStart(index: 0, id: "call_2", name: "finish", kind: .function)),
            .delta(.toolCallDelta(index: 0, arguments: #"{"content": "done"}"#)),
            .delta(.finished(usage: nil)),
        ]
        let client = ContinuityStreamingMockLLMClient(streamSequences: [firstIteration, secondIteration])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])

        var finalHistory: [ChatMessage] = []
        for try await event in agent.stream(userMessage: "Hi", context: EmptyContext()) {
            if case let .finished(_, _, _, history) = event.kind {
                finalHistory = history
            }
        }

        let assistantMessages = finalHistory.compactMap { message -> AssistantMessage? in
            if case let .assistant(assistant) = message { return assistant }
            return nil
        }

        #expect(assistantMessages.count == 1)
        #expect(assistantMessages[0].continuity == continuity)
    }
}

private struct ContinuityEchoParams: Codable, SchemaProviding {
    let message: String

    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

private struct ContinuityEchoOutput: Codable {
    let echoed: String
}
