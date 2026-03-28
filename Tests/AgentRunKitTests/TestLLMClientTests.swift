@testable import AgentRunKit
import AgentRunKitTesting
import Foundation
import Testing

struct JSONSchemaWalkerTests {
    @Test
    func stringProducesTestValue() async throws {
        let value = try await generatedToolArgumentsValue(schema: .string())
        guard case let .string(text) = value else {
            Issue.record("Expected string value")
            return
        }
        #expect(text == "test_0")
    }

    @Test
    func stringWithEnumPicksBySeed() async throws {
        let schema = JSONSchema.string(enumValues: ["a", "b"])
        let value0 = try await generatedToolArgumentsValue(schema: schema, seed: 0)
        let value1 = try await generatedToolArgumentsValue(schema: schema, seed: 1)
        #expect(value0 == .string("a"))
        #expect(value1 == .string("b"))
    }

    @Test
    func stringWithEmptyEnumFallsBack() async throws {
        let value = try await generatedToolArgumentsValue(schema: .string(enumValues: []), seed: 42)
        #expect(value == .string("test_42"))
    }

    @Test
    func integerProducesSeed() async throws {
        let value = try await generatedToolArgumentsValue(schema: .integer(), seed: 7)
        #expect(value == .int(7))
    }

    @Test
    func numberProducesSeedPlusHalf() async throws {
        let value = try await generatedToolArgumentsValue(schema: .number(), seed: 3)
        #expect(value == .double(3.5))
    }

    @Test
    func booleanAlternatesWithSeed() async throws {
        let value0 = try await generatedToolArgumentsValue(schema: .boolean(), seed: 0)
        let value1 = try await generatedToolArgumentsValue(schema: .boolean(), seed: 1)
        #expect(value0 == .bool(true))
        #expect(value1 == .bool(false))
    }

    @Test
    func nullProducesNull() async throws {
        let value = try await generatedToolArgumentsValue(schema: .null)
        #expect(value == .null)
    }

    @Test
    func arrayProducesSingleElement() async throws {
        let value = try await generatedToolArgumentsValue(schema: .array(items: .integer()), seed: 5)
        #expect(value == .array([.int(5)]))
    }

    @Test
    func objectIncludesAllProperties() async throws {
        let schema = JSONSchema.object(
            properties: ["name": .string(), "age": .integer()],
            required: ["name"]
        )
        let value = try await generatedToolArgumentsValue(schema: schema)
        guard case let .object(object) = value else {
            Issue.record("Expected object value")
            return
        }
        #expect(object.count == 2)
        guard case .int = object["age"] else {
            Issue.record("Expected int for age")
            return
        }
        guard case .string = object["name"] else {
            Issue.record("Expected string for name")
            return
        }
    }

    @Test
    func objectSortsKeysForDeterminism() async throws {
        let schema1 = JSONSchema.object(
            properties: ["b": .integer(), "a": .string()],
            required: ["a", "b"]
        )
        let schema2 = JSONSchema.object(
            properties: ["a": .string(), "b": .integer()],
            required: ["a", "b"]
        )
        let json1 = try await generatedToolArgumentsJSON(schema: schema1)
        let json2 = try await generatedToolArgumentsJSON(schema: schema2)
        #expect(json1 == json2)
    }

    @Test
    func emptyObjectProducesEmptyDict() async throws {
        let value = try await generatedToolArgumentsValue(schema: .object(properties: [:], required: []))
        #expect(value == .object([:]))
    }

    @Test
    func anyOfPrefersNonNull() async throws {
        let value = try await generatedToolArgumentsValue(schema: .anyOf([.string(), .null]))
        guard case .string = value else {
            Issue.record("Expected string, got \(value)")
            return
        }
    }

    @Test
    func anyOfAllNullReturnsNull() async throws {
        let value = try await generatedToolArgumentsValue(schema: .anyOf([.null]))
        #expect(value == .null)
    }

    @Test
    func anyOfEmptyReturnsNull() async throws {
        let value = try await generatedToolArgumentsValue(schema: .anyOf([]))
        #expect(value == .null)
    }

    @Test
    func nestedObjectsRecurseCorrectly() async throws {
        let inner = JSONSchema.object(properties: ["id": .integer()], required: ["id"])
        let schema = JSONSchema.object(
            properties: ["items": .array(items: inner)],
            required: ["items"]
        )
        let value = try await generatedToolArgumentsValue(schema: schema)
        guard case let .object(outer) = value,
              case let .array(array) = outer["items"],
              let first = array.first,
              case let .object(innerObject) = first,
              case let .int(id) = innerObject["id"]
        else {
            Issue.record("Expected nested structure")
            return
        }
        #expect(id == 0)
    }

    @Test
    func seedDeterminism() async throws {
        let schema = JSONSchema.object(
            properties: ["x": .string(), "y": .integer(), "z": .boolean()],
            required: ["x", "y", "z"]
        )
        let json1 = try await generatedToolArgumentsJSON(schema: schema, seed: 42)
        let json2 = try await generatedToolArgumentsJSON(schema: schema, seed: 42)
        #expect(json1 == json2)
    }

    @Test
    func differentSeedsDifferentOutput() async throws {
        let schema = JSONSchema.object(
            properties: ["x": .string(), "y": .integer()],
            required: ["x", "y"]
        )
        let json0 = try await generatedToolArgumentsJSON(schema: schema, seed: 0)
        let json1 = try await generatedToolArgumentsJSON(schema: schema, seed: 100)
        #expect(json0 != json1)
    }

    @Test
    func roundTripCodable() async throws {
        let json = try await generatedToolArgumentsJSON(schema: RoundTripParams.jsonSchema)
        let decoded = try JSONDecoder().decode(RoundTripParams.self, from: Data(json.utf8))
        #expect(!decoded.name.isEmpty)
    }

    @Test
    func negativeSeedDoesNotCrash() async throws {
        let schema = JSONSchema.string(enumValues: ["a", "b", "c"])
        let value = try await generatedToolArgumentsValue(schema: schema, seed: -1)
        guard case .string = value else {
            Issue.record("Expected string")
            return
        }
    }

    @Test
    func intMaxSeedWithEnumDoesNotCrash() async throws {
        let schema = JSONSchema.string(enumValues: ["x", "y"])
        let value = try await generatedToolArgumentsValue(schema: schema, seed: Int.max)
        guard case .string = value else {
            Issue.record("Expected string")
            return
        }
    }

    @Test
    func intMaxSeedWithAnyOfDoesNotCrash() async throws {
        let schema = JSONSchema.anyOf([.string(), .integer()])
        let value = try await generatedToolArgumentsValue(schema: schema, seed: Int.max)
        if case .string = value {
            return
        }
        guard case .int = value else {
            Issue.record("Expected string or int")
            return
        }
    }

    @Test
    func overflowSeedInNestedObjectDoesNotCrash() async throws {
        let schema = JSONSchema.object(
            properties: [
                "a": .string(enumValues: ["x", "y"]),
                "b": .string(enumValues: ["p", "q"]),
            ],
            required: ["a", "b"]
        )
        let value = try await generatedToolArgumentsValue(schema: schema, seed: Int.max)
        guard case let .object(object) = value else {
            Issue.record("Expected object")
            return
        }
        #expect(object.count == 2)
    }
}

// MARK: - Client Behavior Tests

struct TestLLMClientTests {
    @Test
    func firstCallInvokesAllTools() async throws {
        let client = TestLLMClient()
        let tools = [
            ToolDefinition(name: "tool1", description: "T1", parametersSchema: .object(properties: [:], required: [])),
            ToolDefinition(name: "tool2", description: "T2", parametersSchema: .object(properties: [:], required: [])),
        ]
        let response = try await client.generate(
            messages: [.user("Hi")], tools: tools, responseFormat: nil, requestContext: nil
        )
        #expect(response.toolCalls.count == 2)
        #expect(response.toolCalls[0].name == "tool1")
        #expect(response.toolCalls[1].name == "tool2")
    }

    @Test
    func secondCallFinishesWithAgentTools() async throws {
        let client = TestLLMClient()
        let messages: [ChatMessage] = [
            .user("Hi"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "test_call_0", name: "echo", arguments: "{}"),
            ])),
            .tool(id: "test_call_0", name: "echo", content: "result"),
        ]
        let response = try await client.generate(
            messages: messages, tools: [reservedFinishToolDefinition], responseFormat: nil, requestContext: nil
        )
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].name == "finish")
    }

    @Test
    func secondCallReturnsContentWithoutFinishTool() async throws {
        let client = TestLLMClient(finishContent: "Done")
        let messages: [ChatMessage] = [
            .user("Hi"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "test_call_0", name: "echo", arguments: "{}"),
            ])),
            .tool(id: "test_call_0", name: "echo", content: "result"),
        ]
        let response = try await client.generate(
            messages: messages, tools: [], responseFormat: nil, requestContext: nil
        )
        #expect(response.toolCalls.isEmpty)
        #expect(response.content == "Done")
    }

    @Test
    func historyWithToolMessagesDoesNotTriggerFinish() async throws {
        let client = TestLLMClient()
        let schema = JSONSchema.object(properties: [:], required: [])
        let tools = [ToolDefinition(name: "search", description: "Search", parametersSchema: schema)]
        let messages: [ChatMessage] = [
            .user("First question"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "old_1", name: "search", arguments: "{}"),
            ])),
            .tool(id: "old_1", name: "search", content: "old result"),
            .assistant(AssistantMessage(content: "First answer")),
            .user("Second question"),
        ]
        let response = try await client.generate(
            messages: messages, tools: tools, responseFormat: nil, requestContext: nil
        )
        #expect(response.toolCalls.first?.name == "search")
    }

    @Test
    func userMultimodalTreatedAsUserMessage() async throws {
        let client = TestLLMClient()
        let schema = JSONSchema.object(properties: [:], required: [])
        let tools = [ToolDefinition(name: "search", description: "Search", parametersSchema: schema)]
        let messages: [ChatMessage] = [
            .user("First question"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "old_1", name: "search", arguments: "{}"),
            ])),
            .tool(id: "old_1", name: "search", content: "old result"),
            .userMultimodal([.text("New question with image"), .imageURL("https://example.com/img.png")]),
        ]
        let response = try await client.generate(
            messages: messages, tools: tools, responseFormat: nil, requestContext: nil
        )
        #expect(response.toolCalls.first?.name == "search")
    }

    @Test
    func emptyToolsWithFinishToolFinishesImmediately() async throws {
        let client = TestLLMClient()
        let response = try await client.generate(
            messages: [.user("Hi")], tools: [reservedFinishToolDefinition], responseFormat: nil, requestContext: nil
        )
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].name == "finish")
    }

    @Test
    func emptyToolsWithoutFinishToolReturnsContent() async throws {
        let client = TestLLMClient(finishContent: "Done")
        let response = try await client.generate(
            messages: [.user("Hi")], tools: [], responseFormat: nil, requestContext: nil
        )
        #expect(response.toolCalls.isEmpty)
        #expect(response.content == "Done")
    }

    @Test
    func callToolsModeSpecific() async throws {
        let client = TestLLMClient(callTools: .specific(["tool1"]))
        let tools = [
            ToolDefinition(name: "tool1", description: "T1", parametersSchema: .object(properties: [:], required: [])),
            ToolDefinition(name: "tool2", description: "T2", parametersSchema: .object(properties: [:], required: [])),
        ]
        let response = try await client.generate(
            messages: [.user("Hi")], tools: tools, responseFormat: nil, requestContext: nil
        )
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].name == "tool1")
    }

    @Test
    func finishArgsDecodeCorrectly() async throws {
        let client = TestLLMClient(finishContent: "Custom finish")
        let response = try await client.generate(
            messages: [.user("Hi")], tools: [reservedFinishToolDefinition], responseFormat: nil, requestContext: nil
        )
        let finishCall = try #require(response.toolCalls.first { $0.name == "finish" })
        let decoded = try JSONDecoder().decode(FinishArguments.self, from: finishCall.argumentsData)
        #expect(decoded.content == "Custom finish")
        #expect(decoded.reason == nil)
    }

    @Test
    func generatedArgsDecodeCorrectly() async throws {
        let client = TestLLMClient()
        let tools = [
            ToolDefinition(name: "echo", description: "Echo", parametersSchema: RoundTripParams.jsonSchema),
        ]
        let response = try await client.generate(
            messages: [.user("Hi")], tools: tools, responseFormat: nil, requestContext: nil
        )
        let call = try #require(response.toolCalls.first { $0.name == "echo" })
        let decoded = try JSONDecoder().decode(RoundTripParams.self, from: call.argumentsData)
        #expect(!decoded.name.isEmpty)
    }

    @Test
    func responseFormatReturnsStructuredJSON() async throws {
        let client = TestLLMClient()
        let format = ResponseFormat.jsonSchema(StructuredTestOutput.self)
        let response = try await client.generate(
            messages: [.user("Extract")], tools: [], responseFormat: format, requestContext: nil
        )
        #expect(response.toolCalls.isEmpty)
        let decoded = try JSONDecoder().decode(StructuredTestOutput.self, from: Data(response.content.utf8))
        #expect(!decoded.title.isEmpty)
    }

    @Test
    func responseFormatTakesPrecedenceOverTools() async throws {
        let client = TestLLMClient()
        let schema = JSONSchema.object(properties: [:], required: [])
        let tools = [ToolDefinition(name: "search", description: "Search", parametersSchema: schema)]
        let format = ResponseFormat.jsonSchema(StructuredTestOutput.self)
        let response = try await client.generate(
            messages: [.user("Extract")], tools: tools, responseFormat: format, requestContext: nil
        )
        #expect(response.toolCalls.isEmpty)
        #expect(!response.content.isEmpty)
        let decoded = try JSONDecoder().decode(StructuredTestOutput.self, from: Data(response.content.utf8))
        #expect(!decoded.title.isEmpty)
    }

    @Test
    func callToolsModeSpecificNoMatch() async throws {
        let client = TestLLMClient(callTools: .specific(["nonexistent"]))
        let schema = JSONSchema.object(properties: [:], required: [])
        let tools = [
            ToolDefinition(name: "search", description: "Search", parametersSchema: schema),
            reservedFinishToolDefinition,
        ]
        let response = try await client.generate(
            messages: [.user("Hi")], tools: tools, responseFormat: nil, requestContext: nil
        )
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].name == "finish")
    }

    @Test
    func streamEmitsCorrectDeltas() async throws {
        let client = TestLLMClient()
        let tools = [
            ToolDefinition(name: "echo", description: "Echo", parametersSchema: RoundTripParams.jsonSchema),
        ]
        var deltas: [StreamDelta] = []
        for try await delta in client.stream(messages: [.user("Hi")], tools: tools, requestContext: nil) {
            deltas.append(delta)
        }

        guard deltas.count >= 3 else {
            Issue.record("Expected at least 3 deltas, got \(deltas.count)")
            return
        }
        guard case let .toolCallStart(index: idx, id: _, name: name) = deltas[0] else {
            Issue.record("Expected toolCallStart, got \(deltas[0])")
            return
        }
        #expect(idx == 0)
        #expect(name == "echo")
        guard case .toolCallDelta(index: 0, arguments: _) = deltas[1] else {
            Issue.record("Expected toolCallDelta")
            return
        }
        guard case let .finished(usage: usage) = deltas.last else {
            Issue.record("Expected finished delta")
            return
        }
        #expect(usage != nil)
    }

    @Test
    func streamFinishPathWithAgentTools() async throws {
        let client = TestLLMClient()
        let messages: [ChatMessage] = [
            .user("Hi"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "c1", name: "echo", arguments: "{}"),
            ])),
            .tool(id: "c1", name: "echo", content: "result"),
        ]
        var deltas: [StreamDelta] = []
        for try await delta in client.stream(
            messages: messages,
            tools: [reservedFinishToolDefinition],
            requestContext: nil
        ) {
            deltas.append(delta)
        }
        guard deltas.count == 3 else {
            Issue.record("Expected 3 deltas, got \(deltas.count)")
            return
        }
        guard case let .toolCallStart(index: _, id: _, name: name) = deltas[0] else {
            Issue.record("Expected toolCallStart")
            return
        }
        #expect(name == "finish")
    }

    @Test
    func streamFinishPathWithoutFinishToolReturnsContent() async throws {
        let client = TestLLMClient(finishContent: "Done")
        let messages: [ChatMessage] = [
            .user("Hi"),
            .assistant(AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "c1", name: "echo", arguments: "{}"),
            ])),
            .tool(id: "c1", name: "echo", content: "result"),
        ]
        var deltas: [StreamDelta] = []
        for try await delta in client.stream(messages: messages, tools: [], requestContext: nil) {
            deltas.append(delta)
        }
        #expect(deltas.count == 2)
        guard case let .content(text) = deltas[0] else {
            Issue.record("Expected content delta")
            return
        }
        #expect(text == "Done")
    }

    @Test
    func streamEmptyToolsWithFinishTool() async throws {
        let client = TestLLMClient()
        var deltas: [StreamDelta] = []
        for try await delta in client.stream(
            messages: [.user("Hi")],
            tools: [reservedFinishToolDefinition],
            requestContext: nil
        ) {
            deltas.append(delta)
        }
        #expect(deltas.count == 3)
        guard case let .toolCallStart(index: _, id: _, name: name) = deltas[0] else {
            Issue.record("Expected toolCallStart")
            return
        }
        #expect(name == "finish")
    }

    @Test
    func streamEmptyToolsWithoutFinishToolReturnsContent() async throws {
        let client = TestLLMClient(finishContent: "Done")
        var deltas: [StreamDelta] = []
        for try await delta in client.stream(messages: [.user("Hi")], tools: [], requestContext: nil) {
            deltas.append(delta)
        }
        #expect(deltas.count == 2)
        guard case let .content(text) = deltas[0] else {
            Issue.record("Expected content delta")
            return
        }
        #expect(text == "Done")
    }

    @Test
    func streamedArgsDecodeCorrectly() async throws {
        let client = TestLLMClient()
        let tools = [
            ToolDefinition(name: "echo", description: "Echo", parametersSchema: RoundTripParams.jsonSchema),
        ]
        var accumulated = ""
        for try await delta in client.stream(messages: [.user("Hi")], tools: tools, requestContext: nil) {
            if case let .toolCallDelta(index: 0, arguments: args) = delta {
                accumulated += args
            }
        }
        let decoded = try JSONDecoder().decode(RoundTripParams.self, from: Data(accumulated.utf8))
        #expect(!decoded.name.isEmpty)
    }

    @Test
    func agentIntegration() async throws {
        let echoTool = try Tool<RoundTripParams, EchoResult, EmptyContext>(
            name: "echo",
            description: "Echoes name",
            executor: { params, _ in EchoResult(echoed: "Echo: \(params.name)") }
        )
        let client = TestLLMClient()
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])
        let result = try await agent.run(userMessage: "Hello", context: EmptyContext())

        #expect(result.content == "Test completed")
        #expect(result.iterations == 2)
    }

    @Test
    func agentStreamIntegration() async throws {
        let echoTool = try Tool<RoundTripParams, EchoResult, EmptyContext>(
            name: "echo",
            description: "Echoes name",
            executor: { params, _ in EchoResult(echoed: "Echo: \(params.name)") }
        )
        let client = TestLLMClient()
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])

        var events: [StreamEvent] = []
        for try await event in agent.stream(userMessage: "Hello", context: EmptyContext()) {
            events.append(event)
        }

        let finished = events.compactMap { event -> TokenUsage? in
            guard case let .finished(tokenUsage, _, _, _) = event else { return nil }
            return tokenUsage
        }
        #expect(!finished.isEmpty)
    }

    @Test
    func chatSendReturningIntegration() async throws {
        let client = TestLLMClient()
        let chat = Chat<EmptyContext>(client: client)
        let (result, _) = try await chat.send("Extract data", returning: StructuredTestOutput.self)
        #expect(!result.title.isEmpty)
        #expect(result.score == 0)
    }

    @Test
    func chatStreamIntegration() async throws {
        let client = TestLLMClient(finishContent: "Chat done")
        let chat = Chat<EmptyContext>(client: client)
        var events: [StreamEvent] = []
        for try await event in chat.stream("Hello", context: EmptyContext()) {
            events.append(event)
        }
        let finished = events.compactMap { event -> TokenUsage? in
            if case let .finished(usage, _, _, _) = event { return usage }
            return nil
        }
        #expect(!finished.isEmpty)
    }

    @Test
    func chatStreamWithUserDefinedFinishTool() async throws {
        let client = TestLLMClient(finishContent: "Chat done")
        let finishTool = try Tool<RoundTripParams, EchoResult, EmptyContext>(
            name: "finish",
            description: "User-defined finish tool",
            executor: { params, _ in EchoResult(echoed: "Finish: \(params.name)") }
        )
        let chat = Chat<EmptyContext>(client: client, tools: [finishTool])

        var events: [StreamEvent] = []
        for try await event in chat.stream("Hello", context: EmptyContext()) {
            events.append(event)
        }

        #expect(events.contains(.toolCallStarted(name: "finish", id: "test_call_0")))
        let toolCompleted = events.first { event in
            if case let .toolCallCompleted(_, name, result) = event {
                return name == "finish" && result.content.contains("Finish:")
            }
            return false
        }
        #expect(toolCompleted != nil)
        let finished = events.compactMap { event -> TokenUsage? in
            if case let .finished(usage, _, _, _) = event { return usage }
            return nil
        }
        #expect(!finished.isEmpty)
    }

    @Test
    func toolWithOptionalParams() async throws {
        let client = TestLLMClient()
        let tools = [
            ToolDefinition(name: "opt", description: "Optional", parametersSchema: OptionalParams.jsonSchema),
        ]
        let response = try await client.generate(
            messages: [.user("Hi")], tools: tools, responseFormat: nil, requestContext: nil
        )
        let call = try #require(response.toolCalls.first { $0.name == "opt" })
        let decoded = try JSONDecoder().decode(OptionalParams.self, from: call.argumentsData)
        #expect(!decoded.required.isEmpty)
        #expect(decoded.optional != nil)
    }
}

struct TestLLMClientReservedToolTests {
    @Test
    func pruneReservedToolDoesNotTriggerSyntheticFinish() async throws {
        let client = TestLLMClient(finishContent: "Done")
        let response = try await client.generate(
            messages: [.user("Hi")],
            tools: [reservedPruneContextToolDefinition],
            responseFormat: nil,
            requestContext: nil
        )

        #expect(response.toolCalls.isEmpty)
        #expect(response.content == "Done")
    }
}

private func generatedToolArgumentsJSON(
    schema: JSONSchema,
    seed: Int = 0,
    toolName: String = "probe"
) async throws -> String {
    let client = TestLLMClient(seed: seed)
    let response = try await client.generate(
        messages: [.user("Hi")],
        tools: [ToolDefinition(name: toolName, description: "Probe", parametersSchema: schema)],
        responseFormat: nil,
        requestContext: nil
    )
    let call = try #require(response.toolCalls.first)
    return call.arguments
}

private func generatedToolArgumentsValue(
    schema: JSONSchema,
    seed: Int = 0,
    toolName: String = "probe"
) async throws -> JSONValue {
    let json = try await generatedToolArgumentsJSON(schema: schema, seed: seed, toolName: toolName)
    return try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
}

private struct RoundTripParams: Codable, SchemaProviding {
    let name: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["name": .string()], required: ["name"])
    }
}

private struct EchoResult: Codable {
    let echoed: String
}

private struct StructuredTestOutput: Codable, SchemaProviding {
    let title: String
    let score: Int

    static var jsonSchema: JSONSchema {
        .object(
            properties: [
                "title": .string(),
                "score": .integer(),
            ],
            required: ["title", "score"]
        )
    }
}

private struct OptionalParams: Codable, SchemaProviding {
    let required: String
    let optional: String?

    static var jsonSchema: JSONSchema {
        .object(
            properties: [
                "required": .string(),
                "optional": .string().optional(),
            ],
            required: ["required"]
        )
    }
}
