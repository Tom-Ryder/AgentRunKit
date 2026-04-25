@testable import AgentRunKit
import Foundation
import Testing

private actor OverlapDetector {
    private var active: Set<String> = []
    private(set) var overlapPairs: Set<String> = []

    func enter(_ name: String) {
        for existing in active {
            overlapPairs.insert([existing, name].sorted().joined(separator: "+"))
        }
        active.insert(name)
    }

    func exit(_ name: String) {
        active.remove(name)
    }
}

struct ConcurrencySafeBlockingTests {
    @Test
    func defaultUnsafeToolsDoNotOverlap() async throws {
        let detector = OverlapDetector()
        let tool1 = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "unsafe1",
            description: "Unsafe tool 1",
            executor: { _, _ in
                await detector.enter("unsafe1")
                try? await Task.sleep(for: .milliseconds(50))
                await detector.exit("unsafe1")
                return NoopOutput()
            }
        )
        let tool2 = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "unsafe2",
            description: "Unsafe tool 2",
            executor: { _, _ in
                await detector.enter("unsafe2")
                try? await Task.sleep(for: .milliseconds(50))
                await detector.exit("unsafe2")
                return NoopOutput()
            }
        )

        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "c1", name: "unsafe1", arguments: "{}"),
                ToolCall(id: "c2", name: "unsafe2", arguments: "{}"),
            ]),
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "cf", name: "finish", arguments: #"{"content":"done"}"#),
            ]),
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [tool1, tool2])
        let result = try await agent.run(userMessage: "Go", context: EmptyContext())
        #expect(try requireContent(result) == "done")

        let overlaps = await detector.overlapPairs
        #expect(overlaps.isEmpty)
    }

    @Test
    func explicitSafeToolsOverlap() async throws {
        let detector = OverlapDetector()
        let tool1 = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "safe1",
            description: "Safe tool 1",
            isConcurrencySafe: true,
            executor: { _, _ in
                await detector.enter("safe1")
                try? await Task.sleep(for: .milliseconds(100))
                await detector.exit("safe1")
                return NoopOutput()
            }
        )
        let tool2 = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "safe2",
            description: "Safe tool 2",
            isConcurrencySafe: true,
            executor: { _, _ in
                await detector.enter("safe2")
                try? await Task.sleep(for: .milliseconds(100))
                await detector.exit("safe2")
                return NoopOutput()
            }
        )

        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "c1", name: "safe1", arguments: "{}"),
                ToolCall(id: "c2", name: "safe2", arguments: "{}"),
            ]),
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "cf", name: "finish", arguments: #"{"content":"done"}"#),
            ]),
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [tool1, tool2])
        let result = try await agent.run(userMessage: "Go", context: EmptyContext())
        #expect(try requireContent(result) == "done")

        let overlaps = await detector.overlapPairs
        #expect(overlaps.contains("safe1+safe2"))
    }

    @Test
    func mixedDispatchFormsOrderedWaves() async throws {
        let detector = OverlapDetector()
        func makeTool(name: String, safe: Bool) throws -> Tool<NoopParams, NoopOutput, EmptyContext> {
            try Tool(
                name: name,
                description: name,
                isConcurrencySafe: safe,
                executor: { _, _ in
                    await detector.enter(name)
                    try? await Task.sleep(for: .milliseconds(50))
                    await detector.exit(name)
                    return NoopOutput()
                }
            )
        }

        let tools = try [
            makeTool(name: "safe1", safe: true),
            makeTool(name: "safe2", safe: true),
            makeTool(name: "unsafe", safe: false),
            makeTool(name: "safe3", safe: true),
            makeTool(name: "safe4", safe: true),
        ]

        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "c1", name: "safe1", arguments: "{}"),
                ToolCall(id: "c2", name: "safe2", arguments: "{}"),
                ToolCall(id: "c3", name: "unsafe", arguments: "{}"),
                ToolCall(id: "c4", name: "safe3", arguments: "{}"),
                ToolCall(id: "c5", name: "safe4", arguments: "{}"),
            ]),
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "cf", name: "finish", arguments: #"{"content":"done"}"#),
            ]),
        ])
        let agent = Agent<EmptyContext>(client: client, tools: tools)
        let result = try await agent.run(userMessage: "Go", context: EmptyContext())
        #expect(try requireContent(result) == "done")

        let overlaps = await detector.overlapPairs
        #expect(overlaps.contains("safe1+safe2"))
        #expect(overlaps.contains("safe3+safe4"))
        #expect(!overlaps.contains(where: { $0.contains("unsafe") }))
    }

    @Test
    func dispatchOrderPreservedInHistory() async throws {
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "c1", name: "safe1", arguments: "{}"),
                ToolCall(id: "c2", name: "unsafe", arguments: "{}"),
                ToolCall(id: "c3", name: "safe2", arguments: "{}"),
            ]),
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "cf", name: "finish", arguments: #"{"content":"done"}"#),
            ]),
        ])
        let tools: [any AnyTool<EmptyContext>] = try [
            Tool<NoopParams, NoopOutput, EmptyContext>(
                name: "safe1", description: "s1", isConcurrencySafe: true,
                executor: { _, _ in NoopOutput() }
            ),
            Tool<NoopParams, NoopOutput, EmptyContext>(
                name: "unsafe", description: "u",
                executor: { _, _ in NoopOutput() }
            ),
            Tool<NoopParams, NoopOutput, EmptyContext>(
                name: "safe2", description: "s2", isConcurrencySafe: true,
                executor: { _, _ in NoopOutput() }
            ),
        ]
        let agent = Agent<EmptyContext>(client: client, tools: tools)
        let result = try await agent.run(userMessage: "Go", context: EmptyContext())

        let toolNames = result.history.compactMap { msg -> String? in
            guard case let .tool(_, name, _) = msg else { return nil }
            return name
        }
        #expect(toolNames == ["safe1", "unsafe", "safe2"])
    }

    @Test
    func unresolvedToolTreatedAsUnsafe() async throws {
        let detector = OverlapDetector()
        let safeTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "safe",
            description: "Safe tool",
            isConcurrencySafe: true,
            executor: { _, _ in
                await detector.enter("safe")
                try? await Task.sleep(for: .milliseconds(50))
                await detector.exit("safe")
                return NoopOutput()
            }
        )

        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "c1", name: "safe", arguments: "{}"),
                ToolCall(id: "c2", name: "nonexistent", arguments: "{}"),
            ]),
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "cf", name: "finish", arguments: #"{"content":"done"}"#),
            ]),
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [safeTool])
        let result = try await agent.run(userMessage: "Go", context: EmptyContext())
        #expect(try requireContent(result) == "done")

        let overlaps = await detector.overlapPairs
        #expect(overlaps.isEmpty)
    }
}

struct ConcurrencySafeStreamingTests {
    @Test
    func defaultUnsafeToolsDoNotOverlapInStreaming() async throws {
        let detector = OverlapDetector()
        let tool1 = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "unsafe1",
            description: "Unsafe tool 1",
            executor: { _, _ in
                await detector.enter("unsafe1")
                try? await Task.sleep(for: .milliseconds(50))
                await detector.exit("unsafe1")
                return NoopOutput()
            }
        )
        let tool2 = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "unsafe2",
            description: "Unsafe tool 2",
            executor: { _, _ in
                await detector.enter("unsafe2")
                try? await Task.sleep(for: .milliseconds(50))
                await detector.exit("unsafe2")
                return NoopOutput()
            }
        )

        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "c1", name: "unsafe1", kind: .function),
            .toolCallDelta(index: 0, arguments: "{}"),
            .toolCallStart(index: 1, id: "c2", name: "unsafe2", kind: .function),
            .toolCallDelta(index: 1, arguments: "{}"),
            .finished(usage: nil),
        ]
        let finishDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "cf", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
            .finished(usage: nil),
        ]
        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, finishDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [tool1, tool2])

        for try await _ in agent.stream(userMessage: "Go", context: EmptyContext()) {}

        let overlaps = await detector.overlapPairs
        #expect(overlaps.isEmpty)
    }

    @Test
    func completionsDoNotCrossWaveBoundaries() async throws {
        let slowSafe = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "slow_safe",
            description: "Slow safe tool",
            isConcurrencySafe: true,
            executor: { params, _ in
                try await Task.sleep(for: .milliseconds(100))
                return EchoOutput(echoed: "slow: \(params.message)")
            }
        )
        let fastSafe = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "fast_safe",
            description: "Fast safe tool",
            isConcurrencySafe: true,
            executor: { params, _ in EchoOutput(echoed: "fast: \(params.message)") }
        )
        let unsafeTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "unsafe",
            description: "Unsafe tool",
            executor: { params, _ in EchoOutput(echoed: "unsafe: \(params.message)") }
        )

        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "c_slow", name: "slow_safe", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"a"}"#),
            .toolCallStart(index: 1, id: "c_fast", name: "fast_safe", kind: .function),
            .toolCallDelta(index: 1, arguments: #"{"message":"b"}"#),
            .toolCallStart(index: 2, id: "c_unsafe", name: "unsafe", kind: .function),
            .toolCallDelta(index: 2, arguments: #"{"message":"c"}"#),
            .finished(usage: nil),
        ]
        let finishDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "cf", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
            .finished(usage: nil),
        ]
        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, finishDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [slowSafe, fastSafe, unsafeTool])

        var completedNames: [String] = []
        for try await event in agent.stream(userMessage: "Go", context: EmptyContext()) {
            if case let .toolCallCompleted(_, name, _) = event.kind {
                completedNames.append(name)
            }
        }

        #expect(completedNames.count == 3)
        let unsafeIndex = try #require(completedNames.firstIndex(of: "unsafe"))
        let slowIndex = try #require(completedNames.firstIndex(of: "slow_safe"))
        let fastIndex = try #require(completedNames.firstIndex(of: "fast_safe"))
        #expect(slowIndex < unsafeIndex)
        #expect(fastIndex < unsafeIndex)
    }

    @Test
    func streamingDispatchOrderPreservedInHistory() async throws {
        let safeTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "safe",
            description: "Safe tool",
            isConcurrencySafe: true,
            executor: { _, _ in NoopOutput() }
        )
        let unsafeTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "unsafe",
            description: "Unsafe tool",
            executor: { _, _ in NoopOutput() }
        )

        let firstDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "c1", name: "safe", kind: .function),
            .toolCallDelta(index: 0, arguments: "{}"),
            .toolCallStart(index: 1, id: "c2", name: "unsafe", kind: .function),
            .toolCallDelta(index: 1, arguments: "{}"),
            .finished(usage: nil),
        ]
        let finishDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "cf", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"done"}"#),
            .finished(usage: nil),
        ]
        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, finishDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [safeTool, unsafeTool])

        var history: [ChatMessage] = []
        for try await event in agent.stream(userMessage: "Go", context: EmptyContext()) {
            if case let .finished(_, _, _, hist) = event.kind {
                history = hist
            }
        }

        let toolNames = history.compactMap { msg -> String? in
            guard case let .tool(_, name, _) = msg else { return nil }
            return name
        }
        #expect(toolNames == ["safe", "unsafe"])
    }
}

struct SubAgentConcurrencySafeTests {
    @Test
    func defaultUnsafeSiblingSubAgentsDoNotOverlap() async throws {
        let detector = OverlapDetector()

        func makeChild(name: String) throws -> Agent<SubAgentContext<EmptyContext>> {
            let sleepTool = try Tool<NoopParams, NoopOutput, SubAgentContext<EmptyContext>>(
                name: "work",
                description: "Does work",
                executor: { _, _ in
                    await detector.enter(name)
                    try? await Task.sleep(for: .milliseconds(50))
                    await detector.exit(name)
                    return NoopOutput()
                }
            )
            let workDeltas: [StreamDelta] = [
                .toolCallStart(index: 0, id: "\(name)_w", name: "work", kind: .function),
                .toolCallDelta(index: 0, arguments: "{}"),
                .finished(usage: nil),
            ]
            let finishDeltas: [StreamDelta] = [
                .toolCallStart(index: 0, id: "\(name)_f", name: "finish", kind: .function),
                .toolCallDelta(index: 0, arguments: #"{"content":"\#(name) done"}"#),
                .finished(usage: nil),
            ]
            return Agent<SubAgentContext<EmptyContext>>(
                client: StreamingMockLLMClient(streamSequences: [workDeltas, finishDeltas]),
                tools: [sleepTool]
            )
        }

        let tool1 = try SubAgentTool<QueryParams, EmptyContext>(
            name: "sub1", description: "Sub 1",
            agent: makeChild(name: "sub1"),
            messageBuilder: { $0.query }
        )
        let tool2 = try SubAgentTool<QueryParams, EmptyContext>(
            name: "sub2", description: "Sub 2",
            agent: makeChild(name: "sub2"),
            messageBuilder: { $0.query }
        )

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "cs1", name: "sub1", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"query":"q1"}"#),
            .toolCallStart(index: 1, id: "cs2", name: "sub2", kind: .function),
            .toolCallDelta(index: 1, arguments: #"{"query":"q2"}"#),
            .finished(usage: nil),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "pf", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"parent done"}"#),
            .finished(usage: nil),
        ]
        let parentClient = StreamingMockLLMClient(streamSequences: [parentDeltas1, parentDeltas2])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool1, tool2])

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await _ in parentAgent.stream(userMessage: "Go", context: ctx) {}

        let overlaps = await detector.overlapPairs
        #expect(overlaps.isEmpty)
    }

    @Test
    func explicitSafeSiblingSubAgentsCanOverlap() async throws {
        let detector = OverlapDetector()

        func makeChild(name: String) throws -> Agent<SubAgentContext<EmptyContext>> {
            let sleepTool = try Tool<NoopParams, NoopOutput, SubAgentContext<EmptyContext>>(
                name: "work",
                description: "Does work",
                executor: { _, _ in
                    await detector.enter(name)
                    try? await Task.sleep(for: .milliseconds(100))
                    await detector.exit(name)
                    return NoopOutput()
                }
            )
            let workDeltas: [StreamDelta] = [
                .toolCallStart(index: 0, id: "\(name)_w", name: "work", kind: .function),
                .toolCallDelta(index: 0, arguments: "{}"),
                .finished(usage: nil),
            ]
            let finishDeltas: [StreamDelta] = [
                .toolCallStart(index: 0, id: "\(name)_f", name: "finish", kind: .function),
                .toolCallDelta(index: 0, arguments: #"{"content":"\#(name) done"}"#),
                .finished(usage: nil),
            ]
            return Agent<SubAgentContext<EmptyContext>>(
                client: StreamingMockLLMClient(streamSequences: [workDeltas, finishDeltas]),
                tools: [sleepTool]
            )
        }

        let tool1 = try SubAgentTool<QueryParams, EmptyContext>(
            name: "sub1", description: "Sub 1",
            agent: makeChild(name: "sub1"),
            isConcurrencySafe: true,
            messageBuilder: { $0.query }
        )
        let tool2 = try SubAgentTool<QueryParams, EmptyContext>(
            name: "sub2", description: "Sub 2",
            agent: makeChild(name: "sub2"),
            isConcurrencySafe: true,
            messageBuilder: { $0.query }
        )

        let parentDeltas1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "cs1", name: "sub1", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"query":"q1"}"#),
            .toolCallStart(index: 1, id: "cs2", name: "sub2", kind: .function),
            .toolCallDelta(index: 1, arguments: #"{"query":"q2"}"#),
            .finished(usage: nil),
        ]
        let parentDeltas2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "pf", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content":"parent done"}"#),
            .finished(usage: nil),
        ]
        let parentClient = StreamingMockLLMClient(streamSequences: [parentDeltas1, parentDeltas2])
        let parentAgent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [tool1, tool2])

        let ctx = SubAgentContext(inner: EmptyContext(), maxDepth: 3)
        for try await _ in parentAgent.stream(userMessage: "Go", context: ctx) {}

        let overlaps = await detector.overlapPairs
        #expect(overlaps.contains("sub1+sub2"))
    }
}

struct ApprovalAboveWaveSchedulingTests {
    @Test
    func approvalPartitionPreventsOverlapOfSafeTools() async throws {
        let detector = OverlapDetector()
        let autoTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "auto",
            description: "Auto-approved safe tool",
            isConcurrencySafe: true,
            executor: { _, _ in
                await detector.enter("auto")
                try? await Task.sleep(for: .milliseconds(50))
                await detector.exit("auto")
                return NoopOutput()
            }
        )
        let gatedTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "gated",
            description: "Approval-required safe tool",
            isConcurrencySafe: true,
            executor: { _, _ in
                await detector.enter("gated")
                try? await Task.sleep(for: .milliseconds(50))
                await detector.exit("gated")
                return NoopOutput()
            }
        )

        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "c1", name: "auto", arguments: "{}"),
                ToolCall(id: "c2", name: "gated", arguments: "{}"),
            ]),
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "cf", name: "finish", arguments: #"{"content":"done"}"#),
            ]),
        ])
        let config = AgentConfiguration(approvalPolicy: .tools(["gated"]))
        let agent = Agent<EmptyContext>(client: client, tools: [autoTool, gatedTool], configuration: config)
        let counter = CountingApprovalHandler()
        let result = try await agent.run(
            userMessage: "Go", context: EmptyContext(), approvalHandler: counter.handler
        )
        #expect(try requireContent(result) == "done")

        let overlaps = await detector.overlapPairs
        #expect(overlaps.isEmpty)

        let count = await counter.requestCount
        #expect(count == 1)
        let requests = await counter.requests
        #expect(requests.first?.toolName == "gated")
    }
}

private struct EchoParams: Codable, SchemaProviding {
    let message: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

private struct EchoOutput: Codable {
    let echoed: String
}

private struct QueryParams: Codable, SchemaProviding {
    let query: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["query": .string()], required: ["query"])
    }
}

private struct NoopParams: Codable, SchemaProviding {
    static var jsonSchema: JSONSchema {
        .object(properties: [:], required: [])
    }
}

private struct NoopOutput: Codable {}
