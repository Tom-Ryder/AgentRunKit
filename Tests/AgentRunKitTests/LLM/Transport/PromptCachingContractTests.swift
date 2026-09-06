@testable import AgentRunKit
import Foundation
import Testing

@Suite(.tags(.wireFormat, .provider))
struct PromptCachingContractTests {
    enum API: CaseIterable {
        case chat
        case responses
    }

    enum Execution: CaseIterable {
        case blocking
        case streaming
    }

    private let authoredArguments = #"{ "zeta": [{"zeta":true,"alpha":"last"},{"zeta":false,"alpha":"first"}], "#
        + #""alpha":"{ \"z\": 1, \"a\": 2 }" }"#
    private let quotedArgumentsJSON = #""{ \"zeta\": [{\"zeta\":true,\"alpha\":\"last\"},"#
        + #"{\"zeta\":false,\"alpha\":\"first\"}], \"alpha\":\"{ \\\"z\\\": 1, \\\"a\\\": 2 }\" }""#

    private let quotedToolOutputJSON = #""{\"alpha\":\"{ \\\"z\\\": 1, \\\"a\\\": 2 }\",\"zeta\":["#
        + #"{\"alpha\":\"last\",\"zeta\":true},{\"alpha\":\"first\",\"zeta\":false}]}""#

    @Test(arguments: API.allCases, Execution.allCases)
    func schemaBytesSurviveToolTurns(api: API, execution: Execution) async throws {
        let baseURL = try #require(URL(string: "https://prompt-cache-\(UUID().uuidString).test/v1"))
        let path = api == .chat ? "chat/completions" : "responses"
        let requestURL = baseURL.appendingPathComponent(path)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let sequence = HTTPTestResponseSequence(responses: scriptedResponses(api: api, execution: execution))
        HTTPTestURLProtocol.register(url: requestURL) { _ in
            try sequence.nextResponse(url: requestURL)
        }
        defer { HTTPTestURLProtocol.unregister(url: requestURL) }

        let client: any LLMClient = switch api {
        case .chat:
            OpenAIClient(model: "test", baseURL: baseURL, session: session, retryPolicy: .none)
        case .responses:
            ResponsesAPIClient(model: "test", baseURL: baseURL, session: session, retryPolicy: .none, store: false)
        }
        let tool = try Tool<HTTPJSONTestParameters, HTTPJSONTestParameters, EmptyContext>(
            name: "inspect", description: "Inspect", executor: { parameters, _ in parameters }
        )
        let agent = Agent(
            client: client,
            tools: [tool],
            configuration: AgentConfiguration(maxIterations: 2, systemPrompt: "Keep this prefix.")
        )

        switch execution {
        case .blocking:
            let result = try await agent.run(userMessage: "Inspect the entries.", context: EmptyContext())
            #expect(result.content == "done")
            #expect(result.finishReason == .completed)
            #expect(result.iterations == 2)
        case .streaming:
            var events: [StreamEvent] = []
            for try await event in agent.stream(userMessage: "Inspect the entries.", context: EmptyContext()) {
                events.append(event)
            }
            guard case let .finished(_, content, reason, _) = events.last?.kind else {
                Issue.record("Expected a terminal Agent event")
                return
            }
            #expect(content == "done")
            #expect(reason == .completed)
        }

        try assertCapturedRequests(HTTPTestURLProtocol.recordedBodyData(for: requestURL), api: api)
    }

    private func scriptedResponses(api: API, execution: Execution) -> [HTTPTestResponse] {
        let turns = [("inspect", quotedArgumentsJSON), ("finish", #""{\"content\":\"done\"}""#)]
        return turns.map { name, arguments in
            switch api {
            case .chat:
                chatResponse(name: name, arguments: arguments, execution: execution)
            case .responses:
                responsesResponse(name: name, arguments: arguments, execution: execution)
            }
        }
    }

    private func chatResponse(name: String, arguments: String, execution: Execution) -> HTTPTestResponse {
        let function = #"{"name":"\#(name)","arguments":\#(arguments)}"#
        let call = #""id":"call_\#(name)","type":"function","function":\#(function)"#
        let usage = #""usage":{"prompt_tokens":100,"completion_tokens":10}"#
        switch execution {
        case .blocking:
            let payload = #"{"choices":[{"message":{"role":"assistant","content":"","#
                + #""tool_calls":[{\#(call)}]}}],\#(usage)}"#
            return HTTPTestResponse(body: Data(payload.utf8))
        case .streaming:
            let payload = #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,\#(call)}]},"#
                + #""finish_reason":"tool_calls"}],\#(usage)}"#
                + "\n\ndata: [DONE]\n\n"
            return HTTPTestResponse(body: Data(payload.utf8), headers: ["Content-Type": "text/event-stream"])
        }
    }

    private func responsesResponse(name: String, arguments: String, execution: Execution) -> HTTPTestResponse {
        let call = #"{"type":"function_call","id":"item_\#(name)","call_id":"call_\#(name)","#
            + #""name":"\#(name)","arguments":\#(arguments)}"#
        let response = #"{"id":"response_\#(name)","status":"completed","output":[\#(call)],"#
            + #""usage":{"input_tokens":100,"output_tokens":10}}"#
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
}

private extension PromptCachingContractTests {
    func assertCapturedRequests(_ bodies: [Data], api: API) throws {
        try #require(bodies.count == 2)
        let toolFragment = switch api {
        case .chat:
            #""tools":[{"function":{"description":"Inspect","name":"inspect","parameters":"#
                + HTTPJSONTestParameters.schemaJSON + #"},"type":"function"},"#
        case .responses:
            #""tools":[{"description":"Inspect","name":"inspect","parameters":"#
                + HTTPJSONTestParameters.schemaJSON + #","type":"function"},"#
        }
        for body in bodies {
            _ = try #require(body.range(of: Data(toolFragment.utf8)))
        }
        let argumentsFragment = #""arguments":\#(quotedArgumentsJSON)"#
        _ = try #require(bodies[1].range(of: Data(argumentsFragment.utf8)))
        let resultFragment = switch api {
        case .chat:
            #"{"content":\#(quotedToolOutputJSON),"name":"inspect","role":"tool","tool_call_id":"call_inspect"}"#
        case .responses:
            #"{"call_id":"call_inspect","output":\#(quotedToolOutputJSON),"type":"function_call_output"}"#
        }
        _ = try #require(bodies[1].range(of: Data(resultFragment.utf8)))

        let first = try JSONDecoder().decode([String: JSONValue].self, from: bodies[0])
        let second = try JSONDecoder().decode([String: JSONValue].self, from: bodies[1])
        switch api {
        case .chat:
            try assertChatHistory(first: first, second: second)
        case .responses:
            try assertResponsesHistory(first: first, second: second)
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
}
