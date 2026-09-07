@testable import AgentRunKit
import Foundation
import Testing

@Suite(.tags(.wireFormat, .provider))
struct PromptCachingContractTests {
    enum API: CaseIterable {
        case chat
        case responses
        case gemini
    }

    enum Execution: CaseIterable {
        case blocking
        case streaming
    }

    enum UsageScenario: CaseIterable {
        case positive
        case zero
        case absentCache
        case absentUsage
        case inconsistentUsage
    }

    private let authoredArguments = #"{ "zeta": [{"zeta":true,"alpha":"last"},{"zeta":false,"alpha":"first"}], "#
        + #""alpha":"{ \"z\": 1, \"a\": 2 }" }"#
    private let quotedArgumentsJSON = #""{ \"zeta\": [{\"zeta\":true,\"alpha\":\"last\"},"#
        + #"{\"zeta\":false,\"alpha\":\"first\"}], \"alpha\":\"{ \\\"z\\\": 1, \\\"a\\\": 2 }\" }""#

    private let quotedToolOutputJSON = #""{\"alpha\":\"{ \\\"z\\\": 1, \\\"a\\\": 2 }\",\"zeta\":["#
        + #"{\"alpha\":\"last\",\"zeta\":true},{\"alpha\":\"first\",\"zeta\":false}]}""#
    private let toolOutputJSON = #"{"alpha":"{ \"z\": 1, \"a\": 2 }","zeta":["#
        + #"{"alpha":"last","zeta":true},{"alpha":"first","zeta":false}]}"#

    @Test(arguments: API.allCases.flatMap { api in UsageScenario.allCases.map { (api, $0) } }, Execution.allCases)
    func schemaBytesAndUsageSurviveToolTurns(scenario: (API, UsageScenario), execution: Execution) async throws {
        let (api, usageScenario) = scenario
        let baseURL = try #require(URL(string: "https://prompt-cache-\(UUID().uuidString).test/v1"))
        let requestURL = try requestURL(baseURL: baseURL, api: api, execution: execution)
        let session = URLSession(configuration: HTTPTestURLProtocol.configuration())
        defer { session.invalidateAndCancel() }
        let sequence = HTTPTestResponseSequence(responses: scriptedResponses(
            api: api, execution: execution, usageScenario: usageScenario
        ))
        HTTPTestURLProtocol.register(url: requestURL) { _ in
            try sequence.nextResponse(url: requestURL)
        }
        defer { HTTPTestURLProtocol.unregister(url: requestURL) }

        let client: any LLMClient = switch api {
        case .chat:
            OpenAIClient(model: "test", baseURL: baseURL, session: session, retryPolicy: .none)
        case .responses:
            ResponsesAPIClient(model: "test", baseURL: baseURL, session: session, retryPolicy: .none, store: false)
        case .gemini:
            GeminiClient(apiKey: "test", model: "test", baseURL: baseURL, session: session, retryPolicy: .none)
        }
        let tool = try Tool<HTTPJSONTestParameters, HTTPJSONTestParameters, EmptyContext>(
            name: "inspect", description: "Inspect", executor: { parameters, _ in parameters }
        )
        let agent = Agent(
            client: client,
            tools: [tool],
            configuration: AgentConfiguration(maxIterations: 2, systemPrompt: "Keep this prefix.")
        )

        let expectedUsages = expectedUsages(api: api, scenario: usageScenario)
        switch execution {
        case .blocking:
            let result = try await agent.run(userMessage: "Inspect the entries.", context: EmptyContext())
            #expect(result.content == "done")
            #expect(result.finishReason == .completed)
            #expect(result.iterations == 2)
            assertTotals(result.totalTokenUsage, api: api, scenario: usageScenario)
            try assertReturnedHistory(result.history, firstUsage: expectedUsages[0], api: api)
        case .streaming:
            var events: [StreamEvent] = []
            for try await event in agent.stream(userMessage: "Inspect the entries.", context: EmptyContext()) {
                events.append(event)
            }
            guard case let .finished(totals, content, reason, history) = events.last?.kind else {
                Issue.record("Expected a terminal Agent event")
                return
            }
            #expect(content == "done")
            #expect(reason == .completed)
            assertTotals(totals, api: api, scenario: usageScenario)
            try assertReturnedHistory(history, firstUsage: expectedUsages[0], api: api)
            let iterations = events.compactMap { event -> (TokenUsage?, Int)? in
                guard case let .iterationCompleted(usage, iteration, _) = event.kind else { return nil }
                return (usage, iteration)
            }
            #expect(iterations.map(\.0) == expectedUsages)
            #expect(iterations.map(\.1) == [1, 2])
        }

        try assertCapturedRequests(HTTPTestURLProtocol.recordedBodyData(for: requestURL), api: api)
    }
}

private extension PromptCachingContractTests {
    func requestURL(baseURL: URL, api: API, execution: Execution) throws -> URL {
        switch api {
        case .chat:
            baseURL.appendingPathComponent("chat/completions")
        case .responses:
            baseURL.appendingPathComponent("responses")
        case .gemini:
            try #require(URL(string: execution == .blocking
                    ? "\(baseURL)/v1beta/models/test:generateContent?key=test"
                    : "\(baseURL)/v1beta/models/test:streamGenerateContent?key=test&alt=sse"))
        }
    }

    func scriptedResponses(api: API, execution: Execution, usageScenario: UsageScenario) -> [HTTPTestResponse] {
        let turns = [("inspect", quotedArgumentsJSON), ("finish", #""{\"content\":\"done\"}""#)]
        return turns.enumerated().map { index, turn in
            let (name, arguments) = turn
            let usage = usageField(api: api, scenario: usageScenario, turn: index)
            switch api {
            case .chat:
                return chatResponse(name: name, arguments: arguments, usage: usage, execution: execution)
            case .responses:
                return responsesResponse(name: name, arguments: arguments, usage: usage, execution: execution)
            case .gemini:
                return geminiResponse(name: name, usage: usage, execution: execution)
            }
        }
    }

    func usageField(api: API, scenario: UsageScenario, turn: Int) -> String {
        guard scenario != .absentUsage else { return "" }
        let read: Int = switch scenario {
        case .zero: 0
        case .inconsistentUsage where turn == 1: 101
        default: turn == 0 ? 80 : 60
        }
        let write = scenario == .zero || turn == 1 ? 0 : 10
        switch api {
        case .chat:
            let details = scenario == .absentCache ? "" :
                #","prompt_tokens_details":{"cached_tokens":\#(read),"cache_write_tokens":\#(write)}"#
            return #","usage":{"prompt_tokens":100,"completion_tokens":20,"#
                + #""completion_tokens_details":{"reasoning_tokens":5}\#(details)}"#
        case .responses:
            let details = scenario == .absentCache ? "" :
                #","input_tokens_details":{"cached_tokens":\#(read),"cache_write_tokens":\#(write)}"#
            return #","usage":{"input_tokens":100,"output_tokens":20,"#
                + #""output_tokens_details":{"reasoning_tokens":5}\#(details)}"#
        case .gemini:
            let cache = scenario == .absentCache ? "" : #","cachedContentTokenCount":\#(read)"#
            return #","usageMetadata":{"promptTokenCount":100,"toolUsePromptTokenCount":\#(turn == 0 ? 25 : 40),"#
                + #""candidatesTokenCount":15,"thoughtsTokenCount":5\#(cache)}"#
        }
    }

    func chatResponse(name: String, arguments: String, usage: String, execution: Execution) -> HTTPTestResponse {
        let function = #"{"name":"\#(name)","arguments":\#(arguments)}"#
        let call = #""id":"call_\#(name)","type":"function","function":\#(function)"#
        switch execution {
        case .blocking:
            let payload = #"{"choices":[{"message":{"role":"assistant","content":"","#
                + #""tool_calls":[{\#(call)}]}}]\#(usage)}"#
            return HTTPTestResponse(body: Data(payload.utf8))
        case .streaming:
            let payload = #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,\#(call)}]},"#
                + #""finish_reason":"tool_calls"}]\#(usage)}"#
                + "\n\ndata: [DONE]\n\n"
            return HTTPTestResponse(body: Data(payload.utf8), headers: ["Content-Type": "text/event-stream"])
        }
    }

    func responsesResponse(name: String, arguments: String, usage: String, execution: Execution) -> HTTPTestResponse {
        let call = #"{"type":"function_call","id":"item_\#(name)","call_id":"call_\#(name)","#
            + #""name":"\#(name)","arguments":\#(arguments)}"#
        let response = #"{"id":"response_\#(name)","status":"completed","output":[\#(call)]\#(usage)}"#
        switch execution {
        case .blocking:
            return HTTPTestResponse(body: Data(response.utf8))
        case .streaming:
            let start = #"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","#
                + #""id":"item_\#(name)","call_id":"call_\#(name)","name":"\#(name)","arguments":""}}"#
            let delta = #"{"type":"response.function_call_arguments.delta","output_index":0,"delta":\#(arguments)}"#
            let completed = #"{"type":"response.completed","response":\#(response)}"#
            let payload = [start, delta, completed].map { "data: \($0)\n\n" }.joined()
            return HTTPTestResponse(body: Data(payload.utf8), headers: ["Content-Type": "text/event-stream"])
        }
    }

    func geminiResponse(name: String, usage: String, execution: Execution) -> HTTPTestResponse {
        let arguments = name == "inspect" ? authoredArguments : #"{"content":"done"}"#
        let call = #"{"functionCall":{"id":"call_\#(name)","name":"\#(name)","args":\#(arguments)}}"#
        let response = #"{"candidates":[{"content":{"role":"model","parts":[\#(call)]},"#
            + #""finishReason":"STOP"}]\#(usage)}"#
        switch execution {
        case .blocking:
            return HTTPTestResponse(body: Data(response.utf8))
        case .streaming:
            return HTTPTestResponse(
                body: Data("data: \(response)\n\n".utf8), headers: ["Content-Type": "text/event-stream"]
            )
        }
    }
}

private extension PromptCachingContractTests {
    func expectedUsages(api: API, scenario: UsageScenario) -> [TokenUsage?] {
        let firstInput = api == .gemini ? 125 : 100
        let secondInput = api == .gemini ? 140 : 100
        return switch scenario {
        case .positive:
            [
                TokenUsage(input: firstInput, output: 15, reasoning: 5,
                           cacheRead: 80, cacheWrite: api == .gemini ? nil : 10),
                TokenUsage(input: secondInput, output: 15, reasoning: 5,
                           cacheRead: 60, cacheWrite: api == .gemini ? nil : 0)
            ]
        case .zero:
            [
                TokenUsage(input: firstInput, output: 15, reasoning: 5,
                           cacheRead: 0, cacheWrite: api == .gemini ? nil : 0),
                TokenUsage(input: secondInput, output: 15, reasoning: 5,
                           cacheRead: 0, cacheWrite: api == .gemini ? nil : 0)
            ]
        case .absentCache:
            [
                TokenUsage(input: firstInput, output: 15, reasoning: 5, cacheRead: api == .gemini ? 0 : nil),
                TokenUsage(input: secondInput, output: 15, reasoning: 5, cacheRead: api == .gemini ? 0 : nil)
            ]
        case .absentUsage:
            [nil, nil]
        case .inconsistentUsage:
            [
                TokenUsage(input: firstInput, output: 15, reasoning: 5,
                           cacheRead: 80, cacheWrite: api == .gemini ? nil : 10),
                nil
            ]
        }
    }

    func assertTotals(_ totals: TokenUsageTotals, api: API, scenario: UsageScenario) {
        switch scenario {
        case .positive, .zero, .absentCache:
            #expect(totals.input == (api == .gemini ? 265 : 200))
            #expect(totals.output == 30)
            #expect(totals.reasoning == 10)
            #expect(totals.total == (api == .gemini ? 305 : 240))
            #expect(totals.coverage == .complete)
        case .absentUsage:
            #expect(totals.input == 0)
            #expect(totals.output == 0)
            #expect(totals.reasoning == 0)
            #expect(totals.total == 0)
            #expect(totals.coverage == .unavailable)
        case .inconsistentUsage:
            #expect(totals.input == (api == .gemini ? 125 : 100))
            #expect(totals.output == 15)
            #expect(totals.reasoning == 5)
            #expect(totals.total == (api == .gemini ? 145 : 120))
            #expect(totals.coverage == .partial)
        }
        switch scenario {
        case .positive:
            #expect(totals.cacheRead == 140)
            #expect(totals.cacheReadCoverage == .complete)
        case .zero:
            #expect(totals.cacheRead == 0)
            #expect(totals.cacheReadCoverage == .complete)
        case .absentCache:
            #expect(totals.cacheRead == (api == .gemini ? 0 : nil))
            #expect(totals.cacheReadCoverage == (api == .gemini ? .complete : .unavailable))
        case .absentUsage:
            #expect(totals.cacheRead == nil)
            #expect(totals.cacheReadCoverage == .unavailable)
        case .inconsistentUsage:
            #expect(totals.cacheRead == 80)
            #expect(totals.cacheReadCoverage == .partial)
        }
        if api == .gemini || scenario == .absentCache || scenario == .absentUsage {
            #expect(totals.cacheWrite == nil)
            #expect(totals.cacheWriteCoverage == .unavailable)
        } else {
            #expect(totals.cacheWrite == (scenario == .zero ? 0 : 10))
            #expect(totals.cacheWriteCoverage == (scenario == .inconsistentUsage ? .partial : .complete))
        }
    }

    func assertReturnedHistory(_ history: [ChatMessage], firstUsage: TokenUsage?, api: API) throws {
        try history.validateForAgentHistory()
        let continuity: AssistantContinuity? = api == .responses ? AssistantContinuity(
            substrate: .responses,
            payload: .object(["output": .array([.object([
                "type": .string("function_call"), "id": .string("item_inspect"),
                "call_id": .string("call_inspect"), "name": .string("inspect"),
                "arguments": .string(authoredArguments)
            ])])])
        ) : nil
        #expect(history == [
            .system("Keep this prefix."),
            .user("Inspect the entries."),
            .assistant(AssistantMessage(
                content: "",
                toolCalls: [ToolCall(
                    id: "call_inspect", name: "inspect", arguments: api == .gemini ? toolOutputJSON : authoredArguments
                )],
                tokenUsage: firstUsage,
                continuity: continuity
            )),
            .tool(id: "call_inspect", name: "inspect", content: toolOutputJSON)
        ])
    }

    func assertCapturedRequests(_ bodies: [Data], api: API) throws {
        try #require(bodies.count == 2)
        let toolFragment = switch api {
        case .chat:
            #""tools":[{"function":{"description":"Inspect","name":"inspect","parameters":"#
                + HTTPJSONTestParameters.schemaJSON + #"},"type":"function"},"#
        case .responses:
            #""tools":[{"description":"Inspect","name":"inspect","parameters":"#
                + HTTPJSONTestParameters.schemaJSON + #","type":"function"},"#
        case .gemini:
            #""tools":[{"functionDeclarations":[{"description":"Inspect","name":"inspect","parameters":"#
                + HTTPJSONTestParameters.geminiSchemaJSON + #"},"#
        }
        for body in bodies {
            _ = try #require(body.range(of: Data(toolFragment.utf8)))
        }
        let argumentsFragment = api == .gemini
            ? #""functionCall":{"args":\#(toolOutputJSON),"id":"call_inspect","name":"inspect"}"#
            : #""arguments":\#(quotedArgumentsJSON)"#
        _ = try #require(bodies[1].range(of: Data(argumentsFragment.utf8)))
        let resultFragment = switch api {
        case .chat:
            #"{"content":\#(quotedToolOutputJSON),"name":"inspect","role":"tool","tool_call_id":"call_inspect"}"#
        case .responses:
            #"{"call_id":"call_inspect","output":\#(quotedToolOutputJSON),"type":"function_call_output"}"#
        case .gemini:
            #""functionResponse":{"id":"call_inspect","name":"inspect","response":\#(toolOutputJSON)}"#
        }
        _ = try #require(bodies[1].range(of: Data(resultFragment.utf8)))

        let first = try JSONDecoder().decode([String: JSONValue].self, from: bodies[0])
        let second = try JSONDecoder().decode([String: JSONValue].self, from: bodies[1])
        switch api {
        case .chat:
            try assertChatHistory(first: first, second: second)
        case .responses:
            try assertResponsesHistory(first: first, second: second)
        case .gemini:
            try assertGeminiHistory(first: first, second: second)
        }
    }

    func assertChatHistory(first: [String: JSONValue], second: [String: JSONValue]) throws {
        let initial: [JSONValue] = [
            .object(["role": .string("system"), "content": .string("Keep this prefix.")]),
            .object(["role": .string("user"), "content": .string("Inspect the entries.")])
        ]
        #expect(first["messages"] == .array(initial))
        guard case let .array(messages) = second["messages"] else {
            Issue.record("Expected Chat messages")
            return
        }
        try #require(messages.count == 4)
        #expect(Array(messages.prefix(2)) == initial)
        #expect(messages[2] == .object([
            "role": .string("assistant"), "content": .string(""),
            "tool_calls": .array([.object([
                "id": .string("call_inspect"), "type": .string("function"),
                "function": .object(["name": .string("inspect"), "arguments": .string(authoredArguments)])
            ])])
        ]))
        guard case let .object(result) = messages[3], case let .string(content) = result["content"] else {
            Issue.record("Expected a Chat tool result")
            return
        }
        #expect(result["role"] == .string("tool"))
        #expect(result["name"] == .string("inspect"))
        #expect(result["tool_call_id"] == .string("call_inspect"))
        try assertToolOutput(content)
    }

    func assertResponsesHistory(first: [String: JSONValue], second: [String: JSONValue]) throws {
        for body in [first, second] {
            #expect(body["store"] == .bool(false))
            #expect(body["previous_response_id"] == nil)
            #expect(body["instructions"] == .string("Keep this prefix."))
        }
        let initial = JSONValue.object([
            "type": .string("message"), "role": .string("user"), "content": .string("Inspect the entries.")
        ])
        #expect(first["input"] == .array([initial]))
        guard case let .array(input) = second["input"] else {
            Issue.record("Expected Responses input")
            return
        }
        try #require(input.count == 3)
        #expect(input[0] == initial)
        guard case let .object(call) = input[1],
              case let .object(result) = input[2],
              case let .string(content) = result["output"] else {
            Issue.record("Expected a Responses function call and result")
            return
        }
        #expect(call["type"] == .string("function_call"))
        #expect(call["call_id"] == .string("call_inspect"))
        #expect(call["name"] == .string("inspect"))
        #expect(call["arguments"] == .string(authoredArguments))
        #expect(result["type"] == .string("function_call_output"))
        #expect(result["call_id"] == .string("call_inspect"))
        try assertToolOutput(content)
    }

    func assertToolOutput(_ content: String) throws {
        let output = try JSONDecoder().decode(HTTPJSONTestParameters.self, from: Data(content.utf8))
        #expect(output == HTTPJSONTestParameters(
            zeta: [.init(zeta: true, alpha: "last"), .init(zeta: false, alpha: "first")],
            alpha: #"{ "z": 1, "a": 2 }"#
        ))
    }

    func assertGeminiHistory(first: [String: JSONValue], second: [String: JSONValue]) throws {
        for body in [first, second] {
            #expect(body["systemInstruction"] == .object([
                "parts": .array([.object(["text": .string("Keep this prefix.")])])
            ]))
        }
        let initial = JSONValue.object([
            "role": .string("user"), "parts": .array([.object(["text": .string("Inspect the entries.")])])
        ])
        #expect(first["contents"] == .array([initial]))
        guard case let .array(contents) = second["contents"] else {
            Issue.record("Expected Gemini contents")
            return
        }
        let arguments = try JSONDecoder().decode(JSONValue.self, from: Data(authoredArguments.utf8))
        #expect(contents == [initial, .object([
            "role": .string("model"), "parts": .array([.object([
                "functionCall": .object([
                    "args": arguments, "id": .string("call_inspect"), "name": .string("inspect")
                ])
            ])])
        ]), .object([
            "role": .string("user"), "parts": .array([.object([
                "functionResponse": .object([
                    "id": .string("call_inspect"), "name": .string("inspect"), "response": arguments
                ])
            ])])
        ])])
    }
}
