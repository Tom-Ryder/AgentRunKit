import AgentRunKit
@testable import AgentRunKitMLX
import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Testing
import Tokenizers

@Suite(.serialized) struct MLXMessageMapperTests {
    @Test func systemMessage() {
        let dicts = MLXMessageMapper.mapMessages([.system("You are helpful.")])
        #expect(dicts.count == 1)
        let dict = dicts[0]
        #expect(dict["role"] as? String == "system")
        #expect(dict["content"] as? String == "You are helpful.")
    }

    @Test func userMessage() {
        let dicts = MLXMessageMapper.mapMessages([.user("Hello")])
        #expect(dicts.count == 1)
        let dict = dicts[0]
        #expect(dict["role"] as? String == "user")
        #expect(dict["content"] as? String == "Hello")
    }

    @Test func multimodalMessageExtractsTextOnly() {
        let parts: [ContentPart] = [
            .text("First"),
            .imageURL("https://example.com/img.png"),
            .text("Second")
        ]
        let dicts = MLXMessageMapper.mapMessages([.userMultimodal(parts)])
        #expect(dicts.count == 1)
        let dict = dicts[0]
        #expect(dict["role"] as? String == "user")
        #expect(dict["content"] as? String == "First\nSecond")
    }

    @Test func assistantContentOnly() {
        let msg = AssistantMessage(content: "Sure, here is your answer.")
        let dicts = MLXMessageMapper.mapMessages([.assistant(msg)])
        #expect(dicts.count == 1)
        let dict = dicts[0]
        #expect(dict["role"] as? String == "assistant")
        #expect(dict["content"] as? String == "Sure, here is your answer.")
        #expect(dict["tool_calls"] == nil)
    }

    @Test func assistantWithToolCalls() throws {
        let msg = AssistantMessage(
            content: "",
            toolCalls: [AgentRunKit.ToolCall(id: "call_1", name: "get_weather", arguments: "{\"city\":\"London\"}")]
        )
        let dicts = MLXMessageMapper.mapMessages([.assistant(msg)])
        let dict = dicts[0]
        #expect(dict["role"] as? String == "assistant")

        let toolCalls = try #require(dict["tool_calls"] as? [[String: any Sendable]])
        #expect(toolCalls.count == 1)

        let call = toolCalls[0]
        #expect(call["id"] as? String == "call_1")
        #expect(call["type"] as? String == "function")
        let function = call["function"] as? [String: any Sendable]
        #expect(function?["name"] as? String == "get_weather")
        #expect(function?["arguments"] as? String == "{\"city\":\"London\"}")
    }

    @Test func assistantWithContentAndToolCalls() throws {
        let msg = AssistantMessage(
            content: "Let me check the weather for you.",
            toolCalls: [AgentRunKit.ToolCall(id: "call_1", name: "get_weather", arguments: "{\"city\":\"Paris\"}")]
        )
        let dicts = MLXMessageMapper.mapMessages([.assistant(msg)])
        let dict = dicts[0]
        #expect(dict["role"] as? String == "assistant")
        #expect(dict["content"] as? String == "Let me check the weather for you.")
        let toolCalls = try #require(dict["tool_calls"] as? [[String: any Sendable]])
        #expect(toolCalls.count == 1)
        let function = try #require(toolCalls[0]["function"] as? [String: any Sendable])
        #expect(function["name"] as? String == "get_weather")
    }

    @Test func assistantWithMultipleToolCalls() throws {
        let msg = AssistantMessage(
            content: "",
            toolCalls: [
                AgentRunKit.ToolCall(id: "call_1", name: "get_weather", arguments: "{\"city\":\"London\"}"),
                AgentRunKit.ToolCall(id: "call_2", name: "get_time", arguments: "{\"tz\":\"UTC\"}")
            ]
        )
        let dicts = MLXMessageMapper.mapMessages([.assistant(msg)])
        let dict = dicts[0]
        let toolCalls = try #require(dict["tool_calls"] as? [[String: any Sendable]])
        #expect(toolCalls.count == 2)
        let weather = try #require(toolCalls[0]["function"] as? [String: any Sendable])
        #expect(weather["name"] as? String == "get_weather")
        let time = try #require(toolCalls[1]["function"] as? [String: any Sendable])
        #expect(time["name"] as? String == "get_time")
        #expect(toolCalls[0]["id"] as? String == "call_1")
        #expect(toolCalls[1]["id"] as? String == "call_2")
    }

    @Test func toolResult() {
        let dicts = MLXMessageMapper.mapMessages([
            .tool(id: "call_1", name: "get_weather", content: "{\"temp\":72}")
        ])
        #expect(dicts.count == 1)
        let dict = dicts[0]
        #expect(dict["role"] as? String == "tool")
        #expect(dict["tool_call_id"] as? String == "call_1")
        #expect(dict["name"] as? String == "get_weather")
        #expect(dict["content"] as? String == "{\"temp\":72}")
    }

    @Test func fullConversationRoundTrip() throws {
        let messages: [ChatMessage] = [
            .system("You are helpful."),
            .user("What is the weather?"),
            .assistant(AssistantMessage(
                content: "",
                toolCalls: [AgentRunKit.ToolCall(id: "call_1", name: "get_weather", arguments: "{\"city\":\"SF\"}")]
            )),
            .tool(id: "call_1", name: "get_weather", content: "{\"temp\":65}")
        ]
        let dicts = MLXMessageMapper.mapMessages(messages)
        #expect(dicts.count == 4)
        #expect(dicts[0]["role"] as? String == "system")
        #expect(dicts[0]["content"] as? String == "You are helpful.")
        #expect(dicts[1]["role"] as? String == "user")
        #expect(dicts[1]["content"] as? String == "What is the weather?")
        #expect(dicts[2]["role"] as? String == "assistant")
        let toolCalls = try #require(dicts[2]["tool_calls"] as? [[String: any Sendable]])
        #expect(toolCalls.count == 1)
        #expect(dicts[3]["role"] as? String == "tool")
        #expect(dicts[3]["content"] as? String == "{\"temp\":65}")
    }
}

@Suite(.serialized) struct MLXToolSpecTests {
    @Test func stringSchema() throws {
        let dict = try testSchemaDict(.string(description: "A city name"))
        #expect(dict["type"] as? String == "string")
        #expect(dict["description"] as? String == "A city name")
    }

    @Test func stringSchemaWithEnum() throws {
        let dict = try testSchemaDict(.string(enumValues: ["red", "green", "blue"]))
        #expect(dict["type"] as? String == "string")
        let values = dict["enum"] as? [String]
        #expect(values == ["red", "green", "blue"])
    }

    @Test func integerSchema() throws {
        let dict = try testSchemaDict(.integer(description: "Count"))
        #expect(dict["type"] as? String == "integer")
        #expect(dict["description"] as? String == "Count")
    }

    @Test func numberSchema() throws {
        let dict = try testSchemaDict(.number())
        #expect(dict["type"] as? String == "number")
        #expect(dict["description"] == nil)
    }

    @Test func booleanSchema() throws {
        let dict = try testSchemaDict(.boolean(description: "Is enabled"))
        #expect(dict["type"] as? String == "boolean")
        #expect(dict["description"] as? String == "Is enabled")
    }

    @Test func nullSchema() throws {
        let dict = try testSchemaDict(.null)
        #expect(dict["type"] as? String == "null")
    }

    @Test func arraySchema() throws {
        let dict = try testSchemaDict(.array(items: .string(), description: "Tags"))
        #expect(dict["type"] as? String == "array")
        #expect(dict["description"] as? String == "Tags")
        let items = dict["items"] as? [String: any Sendable]
        #expect(items?["type"] as? String == "string")
    }

    @Test func objectSchema() throws {
        let dict = try testSchemaDict(.object(
            properties: [
                "city": .string(description: "City name"),
                "units": .string(enumValues: ["celsius", "fahrenheit"])
            ],
            required: ["city"]
        ))
        #expect(dict["type"] as? String == "object")
        #expect(dict["additionalProperties"] as? Bool == false)
        let required = dict["required"] as? [String]
        #expect(required == ["city"])
        let props = dict["properties"] as? [String: any Sendable]
        #expect(props != nil)
        let cityProp = props?["city"] as? [String: any Sendable]
        #expect(cityProp?["type"] as? String == "string")
        let unitsProp = props?["units"] as? [String: any Sendable]
        #expect(unitsProp?["type"] as? String == "string")
        let unitEnum = unitsProp?["enum"] as? [String]
        #expect(unitEnum == ["celsius", "fahrenheit"])
    }

    @Test func anyOfSchema() throws {
        let dict = try testSchemaDict(.anyOf([.string(), .null]))
        let anyOf = dict["anyOf"] as? [[String: any Sendable]]
        #expect(anyOf?.count == 2)
        #expect(anyOf?[0]["type"] as? String == "string")
        #expect(anyOf?[1]["type"] as? String == "null")
    }

    @Test func fullToolDefinitionToToolSpec() {
        let definition = ToolDefinition(
            name: "get_weather",
            description: "Get the weather for a city",
            parametersSchema: .object(
                properties: ["city": .string(description: "City name")],
                required: ["city"]
            )
        )
        let spec = MLXMessageMapper.toolSpec(from: definition)
        #expect(spec["type"] as? String == "function")
        let function = spec["function"] as? [String: any Sendable]
        #expect(function?["name"] as? String == "get_weather")
        #expect(function?["description"] as? String == "Get the weather for a city")
        let params = function?["parameters"] as? [String: any Sendable]
        #expect(params?["type"] as? String == "object")
    }

    private func testSchemaDict(_ schema: JSONSchema) throws -> [String: any Sendable] {
        let definition = ToolDefinition(name: "test", description: "test", parametersSchema: schema)
        let spec = MLXMessageMapper.toolSpec(from: definition)
        let function = try #require(spec["function"] as? [String: any Sendable])
        return try #require(function["parameters"] as? [String: any Sendable])
    }
}

@Suite(.serialized) struct MLXToolCallMappingTests {
    @Test func basicToolCallMapping() throws {
        let mlxCall = MLXLMCommon.ToolCall(
            function: .init(name: "get_weather", arguments: ["city": "London" as any Sendable])
        )
        let mapped = try MLXMessageMapper.mapToolCall(mlxCall, index: 0)
        #expect(mapped.id == "mlx_call_0")
        #expect(mapped.name == "get_weather")
        let parsed = try JSONDecoder().decode(
            [String: String].self, from: Data(mapped.arguments.utf8)
        )
        #expect(parsed["city"] == "London")
    }

    @Test func objectArgumentsUseDeterministicOrder() throws {
        let json = #"{"function":{"name":"inspect","arguments":{"zeta":[{"zeta":true,"alpha":"雪"},"#
            + #"{"zeta":false,"alpha":"first"}],"alpha":"{ \"z\": 1, \"a\": 2 }"}}}"#
        let call = try JSONDecoder().decode(MLXLMCommon.ToolCall.self, from: Data(json.utf8))

        let mapped = try MLXMessageMapper.mapToolCall(call, index: 0)
        let expected = #"{"alpha":"{ \"z\": 1, \"a\": 2 }","zeta":[{"alpha":"雪","zeta":true},"#
            + #"{"alpha":"first","zeta":false}]}"#

        #expect(mapped.arguments == expected)
    }

    @Test(arguments: [Double.infinity, -Double.infinity, Double.nan])
    func nonfiniteArgumentsThrowEncodingFailure(value: Double) throws {
        let call = MLXLMCommon.ToolCall(
            function: .init(name: "measure", arguments: ["value": value])
        )

        do {
            _ = try MLXMessageMapper.mapToolCall(call, index: 0)
            Issue.record("Expected an encoding failure")
        } catch let error as AgentError {
            guard case .llmError(.encodingFailed) = error else {
                Issue.record("Expected encodingFailed, got \(error)")
                return
            }
        }
    }

    @Test func emptyArguments() throws {
        let mlxCall = MLXLMCommon.ToolCall(
            function: .init(name: "noop", arguments: [:])
        )
        let mapped = try MLXMessageMapper.mapToolCall(mlxCall, index: 0)
        #expect(mapped.arguments == "{}")
    }

    @Test func sequentialIDs() throws {
        let call = MLXLMCommon.ToolCall(
            function: .init(name: "test", arguments: [:])
        )
        let first = try MLXMessageMapper.mapToolCall(call, index: 0)
        let second = try MLXMessageMapper.mapToolCall(call, index: 1)
        let third = try MLXMessageMapper.mapToolCall(call, index: 2)
        #expect(first.id == "mlx_call_0")
        #expect(second.id == "mlx_call_1")
        #expect(third.id == "mlx_call_2")
    }
}

@Suite(.serialized) struct MLXParameterMergingTests {
    @Test func noExtraFieldsReturnsBase() {
        let base = GenerateParameters(maxTokens: 512, temperature: 0.7)
        let merged = MLXMessageMapper.mergeParameters(base, extraFields: [:])
        #expect(merged.temperature == 0.7)
        #expect(merged.maxTokens == 512)
    }

    @Test func overrideTemperature() {
        let base = GenerateParameters(temperature: 0.7)
        let merged = MLXMessageMapper.mergeParameters(
            base, extraFields: ["temperature": .double(0.3)]
        )
        #expect(merged.temperature == Float(0.3))
        #expect(merged.topP == base.topP)
        #expect(merged.maxTokens == base.maxTokens)
    }

    @Test func overrideTemperatureWithInt() {
        let base = GenerateParameters(temperature: 0.7)
        let merged = MLXMessageMapper.mergeParameters(
            base, extraFields: ["temperature": .int(1)]
        )
        #expect(merged.temperature == Float(1.0))
    }

    @Test func multipleOverrides() {
        let base = GenerateParameters()
        let merged = MLXMessageMapper.mergeParameters(base, extraFields: [
            "temperature": .double(0.9),
            "top_p": .double(0.95),
            "max_tokens": .int(2048),
            "repetition_penalty": .double(1.1)
        ])
        #expect(merged.temperature == Float(0.9))
        #expect(merged.topP == Float(0.95))
        #expect(merged.maxTokens == 2048)
        #expect(merged.repetitionPenalty == Float(1.1))
    }
}

@Suite(.serialized) struct MLXClientHistoryValidationTests {
    private let malformedHistory: [ChatMessage] = [
        .user("Hi"),
        .assistant(AssistantMessage(
            content: "",
            toolCalls: [ToolCall(id: "call_1", name: "lookup", arguments: "{}")]
        )),
    ]

    @Test
    func generateRejectsMalformedHistory() async {
        let client = makeMLXClient()

        await #expect(throws: AgentError.malformedHistory(.unfinishedToolCallBatch(ids: ["call_1"]))) {
            _ = try await client.generate(
                messages: malformedHistory,
                tools: [],
                responseFormat: nil,
                requestContext: nil
            )
        }
    }

    @Test
    func streamRejectsMalformedHistory() async {
        let client = makeMLXClient()

        await #expect(throws: AgentError.malformedHistory(.unfinishedToolCallBatch(ids: ["call_1"]))) {
            for try await _ in client.stream(messages: malformedHistory, tools: [], requestContext: nil) {}
        }
    }

    private func makeMLXClient() -> MLXClient {
        let context = ModelContext(
            configuration: ModelConfiguration(id: "test"),
            model: DummyLanguageModel(),
            processor: DummyInputProcessor(),
            tokenizer: DummyTokenizer()
        )
        return MLXClient(container: ModelContainer(context: context))
    }
}

private final class DummyLanguageModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache _: [KVCache], windowSize _: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        _ = inputs
        _ = cache
        return MLXArray([0])
    }

    func newCache(parameters _: GenerateParameters?) -> [KVCache] {
        []
    }
}

private struct DummyInputProcessor: UserInputProcessor {
    func prepare(input _: UserInput) throws -> LMInput {
        LMInput(tokens: MLXArray([0]))
    }
}

private struct DummyTokenizer: Tokenizer {
    func tokenize(text: String) -> [String] {
        text.split(separator: " ").map(String.init)
    }

    func encode(text _: String) -> [Int] {
        [0]
    }

    func encode(text _: String, addSpecialTokens _: Bool) -> [Int] {
        [0]
    }

    func decode(tokens: [Int], skipSpecialTokens _: Bool) -> String {
        tokens.map(String.init).joined(separator: " ")
    }

    func convertTokenToId(_ token: String) -> Int? {
        Int(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        String(id)
    }

    var bosToken: String? {
        nil
    }

    var bosTokenId: Int? {
        nil
    }

    var eosToken: String? {
        nil
    }

    var eosTokenId: Int? {
        nil
    }

    var unknownToken: String? {
        nil
    }

    var unknownTokenId: Int? {
        nil
    }

    func applyChatTemplate(messages _: [Tokenizers.Message]) throws -> [Int] {
        [0]
    }

    func applyChatTemplate(messages _: [Tokenizers.Message], tools _: [Tokenizers.ToolSpec]?) throws -> [Int] {
        [0]
    }

    func applyChatTemplate(
        messages _: [Tokenizers.Message],
        tools _: [Tokenizers.ToolSpec]?,
        additionalContext _: [String: any Sendable]?
    ) throws -> [Int] {
        [0]
    }

    func applyChatTemplate(
        messages _: [Tokenizers.Message],
        chatTemplate _: Tokenizers.ChatTemplateArgument
    ) throws -> [Int] {
        [0]
    }

    func applyChatTemplate(messages _: [Tokenizers.Message], chatTemplate _: String) throws -> [Int] {
        [0]
    }

    func applyChatTemplate(
        messages _: [Tokenizers.Message],
        chatTemplate _: Tokenizers.ChatTemplateArgument?,
        addGenerationPrompt _: Bool,
        truncation _: Bool,
        maxLength _: Int?,
        tools _: [Tokenizers.ToolSpec]?
    ) throws -> [Int] {
        [0]
    }

    func applyChatTemplate(
        messages _: [Tokenizers.Message],
        chatTemplate _: Tokenizers.ChatTemplateArgument?,
        addGenerationPrompt _: Bool,
        truncation _: Bool,
        maxLength _: Int?,
        tools _: [Tokenizers.ToolSpec]?,
        additionalContext _: [String: any Sendable]?
    ) throws -> [Int] {
        [0]
    }
}
