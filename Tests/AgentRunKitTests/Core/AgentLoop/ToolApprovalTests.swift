@testable import AgentRunKit
import AgentRunKitTesting
import Foundation
import Testing

private struct EchoParams: Codable, SchemaProviding {
    let message: String
}

private struct EchoOutput: Codable {
    let echoed: String
}

private func makeEchoTool() throws -> Tool<EchoParams, EchoOutput, EmptyContext> {
    try Tool(
        name: "echo",
        description: "Echoes input",
        executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
    )
}

private func makeSearchTool() throws -> Tool<EchoParams, EchoOutput, EmptyContext> {
    try Tool(
        name: "search",
        description: "Searches",
        executor: { params, _ in EchoOutput(echoed: "Found: \(params.message)") }
    )
}

private func extractToolContent(_ messages: [ChatMessage]) -> String? {
    for message in messages {
        if case let .tool(_, _, content) = message {
            return content
        }
    }
    return nil
}

// MARK: - Policy Unit Tests

struct ToolApprovalPolicyTests {
    @Test
    func policyNoneNeverRequiresApproval() {
        let policy = ToolApprovalPolicy.none
        #expect(!policy.requiresApproval(toolName: "echo", allowlist: []))
        #expect(!policy.requiresApproval(toolName: "search", allowlist: []))
    }

    @Test
    func policyAllToolsRequiresApproval() {
        let policy = ToolApprovalPolicy.allTools
        #expect(policy.requiresApproval(toolName: "echo", allowlist: []))
        #expect(policy.requiresApproval(toolName: "search", allowlist: []))
    }

    @Test
    func policySpecificOnlyMatchesNamed() {
        let policy = ToolApprovalPolicy.tools(["echo"])
        #expect(policy.requiresApproval(toolName: "echo", allowlist: []))
        #expect(!policy.requiresApproval(toolName: "search", allowlist: []))
    }

    @Test
    func allowlistOverridesPolicy() {
        let policy = ToolApprovalPolicy.allTools
        #expect(!policy.requiresApproval(toolName: "echo", allowlist: ["echo"]))
    }
}

// MARK: - Agent Loop Tests

struct ToolApprovalAgentTests {
    @Test
    func policyNoneExecutesWithoutHandler() async throws {
        let echoTool = try makeEchoTool()
        let client = TestLLMClient(seed: 1)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])
        let result = try await agent.run(userMessage: "Go", context: EmptyContext())
        let content = try requireContent(result)
        #expect(!content.isEmpty)
    }

    @Test
    func policyNoneWithHandlerNeverCallsIt() async throws {
        let echoTool = try makeEchoTool()
        let client = TestLLMClient(seed: 1)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])
        let counter = CountingApprovalHandler()
        let result = try await agent.run(
            userMessage: "Go", context: EmptyContext(), approvalHandler: counter.handler
        )
        let content = try requireContent(result)
        #expect(!content.isEmpty)
        let count = await counter.requestCount
        #expect(count == 0)
    }

    @Test
    func approvedToolExecutesNormally() async throws {
        let echoTool = try makeEchoTool()
        let responses = [
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_1", name: "echo", arguments: #"{"message":"hello"}"#)]
            ),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_f", name: "finish", arguments: #"{"content":"done"}"#)]
            ),
        ]
        let client = MockLLMClient(responses: responses)
        let config = AgentConfiguration(approvalPolicy: .allTools)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let counter = CountingApprovalHandler()
        let result = try await agent.run(
            userMessage: "Go", context: EmptyContext(), approvalHandler: counter.handler
        )
        #expect(try requireContent(result) == "done")
        let count = await counter.requestCount
        #expect(count == 1)
    }

    @Test
    func deniedToolFeedsReasonToLLM() async throws {
        let echoTool = try makeEchoTool()
        let responses = [
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_1", name: "echo", arguments: #"{"message":"hello"}"#)]
            ),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_f", name: "finish", arguments: #"{"content":"denied"}"#)]
            ),
        ]
        let client = CapturingMockLLMClient(responses: responses)
        let config = AgentConfiguration(approvalPolicy: .allTools)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let counter = CountingApprovalHandler(decisions: ["echo": .deny(reason: "Blocked by policy")])
        let result = try await agent.run(
            userMessage: "Go", context: EmptyContext(), approvalHandler: counter.handler
        )
        #expect(try requireContent(result) == "denied")
        let capturedMessages = await client.capturedMessages
        let toolMessages = capturedMessages.filter {
            if case .tool = $0 { return true }
            return false
        }
        #expect(toolMessages.count == 1)
        if case let .tool(_, _, content) = toolMessages.first {
            #expect(content.contains("Blocked by policy"))
        }
    }

    @Test
    func deniedToolWithNilReasonUsesDefault() async throws {
        let echoTool = try makeEchoTool()
        let responses = [
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_1", name: "echo", arguments: #"{"message":"hello"}"#)]
            ),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_f", name: "finish", arguments: #"{"content":"ok"}"#)]
            ),
        ]
        let client = CapturingMockLLMClient(responses: responses)
        let config = AgentConfiguration(approvalPolicy: .allTools)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let counter = CountingApprovalHandler(decisions: ["echo": .deny(reason: nil)])
        _ = try await agent.run(
            userMessage: "Go", context: EmptyContext(), approvalHandler: counter.handler
        )
        let capturedMessages = await client.capturedMessages
        let toolMessages = capturedMessages.filter {
            if case .tool = $0 { return true }
            return false
        }
        #expect(toolMessages.count == 1)
        guard case let .tool(_, _, content) = toolMessages.first else {
            Issue.record("Expected denied tool message")
            return
        }
        #expect(content.contains("denied"))
    }

    @Test
    func approveAlwaysSkipsHandlerOnSubsequentCalls() async throws {
        let echoTool = try makeEchoTool()
        let responses = [
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_1", name: "echo", arguments: #"{"message":"first"}"#)]
            ),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_2", name: "echo", arguments: #"{"message":"second"}"#)]
            ),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_f", name: "finish", arguments: #"{"content":"done"}"#)]
            ),
        ]
        let client = MockLLMClient(responses: responses)
        let config = AgentConfiguration(approvalPolicy: .allTools)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let counter = CountingApprovalHandler(defaultDecision: .approveAlways)
        _ = try await agent.run(
            userMessage: "Go", context: EmptyContext(), approvalHandler: counter.handler
        )
        let count = await counter.requestCount
        #expect(count == 1)
    }

    @Test
    func modifiedArgumentsUsedForExecution() async throws {
        let echoTool = try makeEchoTool()
        let responses = [
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_1", name: "echo", arguments: #"{"message":"original"}"#)]
            ),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_f", name: "finish", arguments: #"{"content":"done"}"#)]
            ),
        ]
        let client = CapturingMockLLMClient(responses: responses)
        let config = AgentConfiguration(approvalPolicy: .allTools)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let counter = CountingApprovalHandler(
            decisions: ["echo": .approveWithModifiedArguments(#"{"message":"modified"}"#)]
        )
        _ = try await agent.run(
            userMessage: "Go", context: EmptyContext(), approvalHandler: counter.handler
        )
        let capturedMessages = await client.capturedMessages
        let toolMessages = capturedMessages.filter {
            if case .tool = $0 { return true }
            return false
        }
        #expect(toolMessages.count == 1)
        guard case let .tool(_, _, content) = toolMessages.first else {
            Issue.record("Expected modified tool message")
            return
        }
        #expect(content.contains("modified"))
    }

    @Test
    func mixedBatchAutoExecuteAndApproval() async throws {
        let echoTool = try makeEchoTool()
        let searchTool = try makeSearchTool()
        let responses = [
            AssistantMessage(
                content: "",
                toolCalls: [
                    ToolCall(id: "call_e", name: "echo", arguments: #"{"message":"hello"}"#),
                    ToolCall(id: "call_s", name: "search", arguments: #"{"message":"world"}"#),
                ]
            ),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_f", name: "finish", arguments: #"{"content":"done"}"#)]
            ),
        ]
        let client = CapturingMockLLMClient(responses: responses)
        let config = AgentConfiguration(approvalPolicy: .tools(["search"]))
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool, searchTool], configuration: config)
        let counter = CountingApprovalHandler()
        _ = try await agent.run(
            userMessage: "Go", context: EmptyContext(), approvalHandler: counter.handler
        )
        let count = await counter.requestCount
        #expect(count == 1)
        let requests = await counter.requests
        #expect(requests.first?.toolName == "search")
    }

    @Test
    func specificToolsPolicyOnlyGatesNamed() async throws {
        let echoTool = try makeEchoTool()
        let searchTool = try makeSearchTool()
        let responses = [
            AssistantMessage(
                content: "",
                toolCalls: [
                    ToolCall(id: "call_e", name: "echo", arguments: #"{"message":"hello"}"#),
                ]
            ),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_f", name: "finish", arguments: #"{"content":"done"}"#)]
            ),
        ]
        let client = MockLLMClient(responses: responses)
        let config = AgentConfiguration(approvalPolicy: .tools(["search"]))
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool, searchTool], configuration: config)
        let counter = CountingApprovalHandler()
        _ = try await agent.run(
            userMessage: "Go", context: EmptyContext(), approvalHandler: counter.handler
        )
        let count = await counter.requestCount
        #expect(count == 0)
    }

    @Test
    func allowlistResetsAcrossInvocations() async throws {
        let echoTool = try makeEchoTool()
        let responses = [
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_1", name: "echo", arguments: #"{"message":"a"}"#)]
            ),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_f", name: "finish", arguments: #"{"content":"done"}"#)]
            ),
        ]
        let client = MockLLMClient(responses: responses + responses)
        let config = AgentConfiguration(approvalPolicy: .allTools)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let counter = CountingApprovalHandler(defaultDecision: .approveAlways)
        _ = try await agent.run(userMessage: "Go", context: EmptyContext(), approvalHandler: counter.handler)
        _ = try await agent.run(userMessage: "Go", context: EmptyContext(), approvalHandler: counter.handler)
        let count = await counter.requestCount
        #expect(count == 2)
    }

    @Test
    func unknownToolSkipsApprovalHandler() async throws {
        let echoTool = try makeEchoTool()
        let responses = [
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_1", name: "nonexistent", arguments: #"{"message":"hi"}"#)]
            ),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_f", name: "finish", arguments: #"{"content":"done"}"#)]
            ),
        ]
        let client = CapturingMockLLMClient(responses: responses)
        let config = AgentConfiguration(approvalPolicy: .allTools)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let counter = CountingApprovalHandler()
        _ = try await agent.run(
            userMessage: "Go", context: EmptyContext(), approvalHandler: counter.handler
        )
        let count = await counter.requestCount
        #expect(count == 0)
        let toolMessages = await client.capturedMessages.filter {
            if case .tool = $0 { return true }
            return false
        }
        #expect(toolMessages.count == 1)
        if case let .tool(_, _, content) = toolMessages.first {
            #expect(content.contains("does not exist"))
        }
    }

    @Test
    func streamingApproveAlwaysSkipsSubsequentHandlerCalls() async throws {
        let echoTool = try makeEchoTool()
        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"first"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"second"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let finishDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_f", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
            .finished(usage: nil),
        ]
        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, secondDeltas, finishDeltas])
        let config = AgentConfiguration(approvalPolicy: .allTools)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let counter = CountingApprovalHandler(defaultDecision: .approveAlways)

        for try await _ in agent.stream(
            userMessage: "Go", context: EmptyContext(), approvalHandler: counter.handler
        ) {}

        let count = await counter.requestCount
        #expect(count == 1)
    }

    @Test
    func streamingApproveWithModifiedArguments() async throws {
        let echoTool = try makeEchoTool()
        let deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"original"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let finishDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_f", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
            .finished(usage: nil),
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas, finishDeltas])
        let config = AgentConfiguration(approvalPolicy: .allTools)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let counter = CountingApprovalHandler(
            decisions: ["echo": .approveWithModifiedArguments(#"{"message":"modified"}"#)]
        )

        var toolResults: [ToolResult] = []
        for try await event in agent.stream(
            userMessage: "Go", context: EmptyContext(), approvalHandler: counter.handler
        ) {
            if case let .toolCallCompleted(_, name, result) = event.kind, name == "echo" {
                toolResults.append(result)
            }
        }

        #expect(toolResults.count == 1)
        #expect(toolResults[0].content.contains("modified"))
    }
}

// MARK: - Streaming Tests

struct ToolApprovalStreamingTests {
    @Test
    func streamEmitsApprovalEvents() async throws {
        let echoTool = try makeEchoTool()
        let deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"hello"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let finishDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_f", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
            .finished(usage: nil),
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas, finishDeltas])
        let config = AgentConfiguration(approvalPolicy: .allTools)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let counter = CountingApprovalHandler()

        var events: [StreamEvent] = []
        for try await event in agent.stream(
            userMessage: "Go", context: EmptyContext(), approvalHandler: counter.handler
        ) {
            events.append(event)
        }

        let approvalRequested = events.contains {
            if case .toolApprovalRequested = $0.kind { return true }
            return false
        }
        let approvalResolved = events.contains {
            if case .toolApprovalResolved = $0.kind { return true }
            return false
        }
        #expect(approvalRequested)
        #expect(approvalResolved)
    }

    @Test
    func deniedToolEmitsToolCallCompleted() async throws {
        let echoTool = try makeEchoTool()
        let deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"hello"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let finishDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_f", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"denied"}"#),
            .finished(usage: nil),
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas, finishDeltas])
        let config = AgentConfiguration(approvalPolicy: .allTools)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let counter = CountingApprovalHandler(decisions: ["echo": .deny(reason: "Blocked")])

        var completedToolNames: [String] = []
        for try await event in agent.stream(
            userMessage: "Go", context: EmptyContext(), approvalHandler: counter.handler
        ) {
            if case let .toolCallCompleted(_, name, result) = event.kind {
                completedToolNames.append(name)
                if name == "echo" {
                    #expect(result.isError)
                    #expect(result.content.contains("Blocked"))
                }
            }
        }
        #expect(completedToolNames.contains("echo"))
    }

    @Test
    func deniedToolResultIsTruncatedBeforeStreamingHistoryReuse() async throws {
        let echoTool = try makeEchoTool()
        let denialReason = String(repeating: "B", count: 200)
        let deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"hello"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let finishDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_f", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"denied"}"#),
            .finished(usage: nil),
        ]
        let client = CapturingStreamingMockLLMClient(streamSequences: [deltas, finishDeltas])
        let config = AgentConfiguration(maxToolResultCharacters: 50, approvalPolicy: .allTools)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let counter = CountingApprovalHandler(decisions: ["echo": .deny(reason: denialReason)])

        var events: [StreamEvent] = []
        for try await event in agent.stream(
            userMessage: "Go", context: EmptyContext(), approvalHandler: counter.handler
        ) {
            events.append(event)
        }

        let expected = ContextCompactor.truncateToolResult(denialReason, maxCharacters: 50)
        let toolCompleted = events.first { event in
            if case let .toolCallCompleted(_, name, _) = event.kind { name == "echo" } else { false }
        }
        guard case let .toolCallCompleted(_, _, result) = toolCompleted?.kind else {
            Issue.record("Expected toolCallCompleted event")
            return
        }
        #expect(result.isError)
        #expect(result.content == expected)

        guard case let .finished(_, _, _, history) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(extractToolContent(history) == expected)

        let allCapturedMessages = await client.allCapturedMessages
        #expect(allCapturedMessages.count == 2)
        #expect(extractToolContent(allCapturedMessages[1]) == expected)
    }

    @Test
    func approvalEventsInCorrectOrder() async throws {
        let echoTool = try makeEchoTool()
        let deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"hello"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let finishDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_f", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
            .finished(usage: nil),
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas, finishDeltas])
        let config = AgentConfiguration(approvalPolicy: .allTools)
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let counter = CountingApprovalHandler()

        var eventNames: [String] = []
        for try await event in agent.stream(
            userMessage: "Go", context: EmptyContext(), approvalHandler: counter.handler
        ) {
            switch event.kind {
            case .toolCallStarted: eventNames.append("started")
            case .toolApprovalRequested: eventNames.append("requested")
            case .toolApprovalResolved: eventNames.append("resolved")
            case .toolCallCompleted: eventNames.append("completed")
            default: break
            }
        }
        let echoEvents = eventNames.prefix(4)
        #expect(Array(echoEvents) == ["started", "requested", "resolved", "completed"])
    }
}

// MARK: - Ordering Tests

struct ToolApprovalOrderingTests {
    @Test
    func mixedBatchPreservesOriginalOrder() async throws {
        let echoTool = try makeEchoTool()
        let searchTool = try makeSearchTool()
        let responses = [
            AssistantMessage(
                content: "",
                toolCalls: [
                    ToolCall(id: "call_e", name: "echo", arguments: #"{"message":"first"}"#),
                    ToolCall(id: "call_s", name: "search", arguments: #"{"message":"second"}"#),
                ]
            ),
            AssistantMessage(
                content: "",
                toolCalls: [ToolCall(id: "call_f", name: "finish", arguments: #"{"content":"done"}"#)]
            ),
        ]
        let client = CapturingMockLLMClient(responses: responses)
        let config = AgentConfiguration(approvalPolicy: .tools(["search"]))
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool, searchTool], configuration: config)
        let counter = CountingApprovalHandler()
        _ = try await agent.run(
            userMessage: "Go", context: EmptyContext(), approvalHandler: counter.handler
        )
        let capturedMessages = await client.capturedMessages
        let toolMessages = capturedMessages.compactMap { msg -> (String, String)? in
            if case let .tool(_, name, content) = msg { return (name, content) }
            return nil
        }
        #expect(toolMessages.count == 2)
        #expect(toolMessages[0].0 == "echo")
        #expect(toolMessages[1].0 == "search")
    }
}
