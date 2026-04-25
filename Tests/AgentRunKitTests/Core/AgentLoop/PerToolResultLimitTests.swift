@testable import AgentRunKit
import Foundation
import Testing

private struct LimitedTool: AnyTool {
    typealias Context = EmptyContext
    let name: String
    let description = "Returns configurable output"
    let parametersSchema: JSONSchema = .object(properties: ["message": .string()], required: ["message"])
    let maxResultCharacters: Int?
    private let output: String

    init(name: String = "limited", maxResultCharacters: Int?, output: String) {
        self.name = name
        self.maxResultCharacters = maxResultCharacters
        self.output = output
    }

    func execute(arguments _: Data, context _: EmptyContext) async throws -> ToolResult {
        .success(output)
    }
}

private actor MockClient: LLMClient {
    let contextWindowSize: Int? = nil
    private let responses: [AssistantMessage]
    private var callIndex = 0
    private(set) var allCapturedMessages: [[ChatMessage]] = []

    init(responses: [AssistantMessage]) {
        self.responses = responses
    }

    func generate(
        messages: [ChatMessage], tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?, requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        allCapturedMessages.append(messages)
        defer { callIndex += 1 }
        guard callIndex < responses.count else {
            throw AgentError.llmError(.other("No more mock responses"))
        }
        return responses[callIndex]
    }

    nonisolated func stream(
        messages _: [ChatMessage], tools _: [ToolDefinition], requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private let finishCall = ToolCall(id: "call_finish", name: "finish", arguments: #"{"content": "done"}"#)

private func extractToolContent(_ messages: [ChatMessage]) -> String? {
    for message in messages {
        if case let .tool(_, _, content) = message { return content }
    }
    return nil
}

private struct EchoParams: Codable, SchemaProviding {
    let message: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

private struct EchoOutput: Codable { let echoed: String }

private enum PerToolResultLimitTestError: Error {
    case nonUTF8
}

private func encodedEchoOutput(_ message: String) throws -> String {
    let data = try JSONEncoder().encode(EchoOutput(echoed: message))
    guard let content = String(bytes: data, encoding: .utf8) else {
        throw PerToolResultLimitTestError.nonUTF8
    }
    return content
}

struct PerToolResultLimitTests {
    @Test
    func perToolLimitOverridesGlobalLimit() async throws {
        let longOutput = String(repeating: "X", count: 200)
        let tool = LimitedTool(maxResultCharacters: 50, output: longOutput)
        let toolCall = ToolCall(id: "call_1", name: "limited", arguments: "{\"message\": \"hi\"}")
        let client = MockClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall]),
            AssistantMessage(content: "", toolCalls: [finishCall]),
        ])
        let config = AgentConfiguration(maxIterations: 5, maxToolResultCharacters: 1000)
        let agent = Agent<EmptyContext>(client: client, tools: [tool], configuration: config)
        let result = try await agent.run(userMessage: "Go", context: EmptyContext())
        #expect(try requireContent(result) == "done")

        let toolContent = try #require(await extractToolContent(client.allCapturedMessages[1]))
        let expected = ContextCompactor.truncateToolResult(longOutput, maxCharacters: 50)
        #expect(toolContent == expected)
        #expect(toolContent.count <= 50)
    }

    @Test
    func perToolNilFallsBackToGlobalLimit() async throws {
        let longOutput = String(repeating: "Y", count: 200)
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo", description: "Echoes",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )
        let echoCall = ToolCall(
            id: "call_1", name: "echo",
            arguments: #"{"message": "\#(longOutput)"}"#
        )
        let client = MockClient(responses: [
            AssistantMessage(content: "", toolCalls: [echoCall]),
            AssistantMessage(content: "", toolCalls: [finishCall]),
        ])
        let config = AgentConfiguration(maxIterations: 5, maxToolResultCharacters: 50)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let result = try await agent.run(userMessage: "Go", context: EmptyContext())
        #expect(try requireContent(result) == "done")

        let toolContent = try #require(await extractToolContent(client.allCapturedMessages[1]))
        let expected = try ContextCompactor.truncateToolResult(
            encodedEchoOutput(longOutput),
            maxCharacters: 50
        )
        #expect(toolContent == expected)
        #expect(toolContent.count <= 50)
    }

    @Test
    func noTruncationWhenBothLimitsAreNil() async throws {
        let longOutput = String(repeating: "Z", count: 200)
        let tool = LimitedTool(maxResultCharacters: nil, output: longOutput)
        let toolCall = ToolCall(id: "call_1", name: "limited", arguments: "{\"message\": \"hi\"}")
        let client = MockClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall]),
            AssistantMessage(content: "", toolCalls: [finishCall]),
        ])
        let config = AgentConfiguration(maxIterations: 5)
        let agent = Agent<EmptyContext>(client: client, tools: [tool], configuration: config)
        let result = try await agent.run(userMessage: "Go", context: EmptyContext())
        #expect(try requireContent(result) == "done")

        let toolContent = try #require(await extractToolContent(client.allCapturedMessages[1]))
        #expect(toolContent == longOutput)
    }

    @Test
    func perToolLimitLargerThanGlobal() async throws {
        let output = String(repeating: "W", count: 200)
        let tool = LimitedTool(maxResultCharacters: 100_000, output: output)
        let toolCall = ToolCall(id: "call_1", name: "limited", arguments: "{\"message\": \"hi\"}")
        let client = MockClient(responses: [
            AssistantMessage(content: "", toolCalls: [toolCall]),
            AssistantMessage(content: "", toolCalls: [finishCall]),
        ])
        let config = AgentConfiguration(maxIterations: 5, maxToolResultCharacters: 100)
        let agent = Agent<EmptyContext>(client: client, tools: [tool], configuration: config)
        let result = try await agent.run(userMessage: "Go", context: EmptyContext())
        #expect(try requireContent(result) == "done")

        let toolContent = try #require(await extractToolContent(client.allCapturedMessages[1]))
        #expect(toolContent == output)
    }

    @Test
    func toolInitWithMaxResultCharactersAppliesToAgent() async throws {
        let longOutput = String(repeating: "Q", count: 200)
        let tool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo", description: "Echoes",
            maxResultCharacters: 50,
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )
        let echoCall = ToolCall(
            id: "call_1", name: "echo",
            arguments: #"{"message": "\#(longOutput)"}"#
        )
        let client = MockClient(responses: [
            AssistantMessage(content: "", toolCalls: [echoCall]),
            AssistantMessage(content: "", toolCalls: [finishCall]),
        ])
        let config = AgentConfiguration(maxIterations: 5, maxToolResultCharacters: 1000)
        let agent = Agent<EmptyContext>(client: client, tools: [tool], configuration: config)
        let result = try await agent.run(userMessage: "Go", context: EmptyContext())
        #expect(try requireContent(result) == "done")

        let toolContent = try #require(await extractToolContent(client.allCapturedMessages[1]))
        let expected = try ContextCompactor.truncateToolResult(
            encodedEchoOutput(longOutput),
            maxCharacters: 50
        )
        #expect(toolContent == expected)
        #expect(toolContent.count <= 50)
    }

    @Test
    func truncateToolResultRespectsSmallLimits() {
        let content = String(repeating: "Q", count: 200)
        for limit in [1, 2, 3, 4, 10, 11, 17, 22] {
            let truncated = ContextCompactor.truncateToolResult(content, maxCharacters: limit)
            #expect(truncated.count <= limit)
        }
    }

    @Test
    func truncateToolResultWithNonPositiveLimitReturnsEmptyString() {
        let content = String(repeating: "R", count: 200)
        #expect(ContextCompactor.truncateToolResult(content, maxCharacters: 0).isEmpty)
        #expect(ContextCompactor.truncateToolResult(content, maxCharacters: -1).isEmpty)
    }
}
