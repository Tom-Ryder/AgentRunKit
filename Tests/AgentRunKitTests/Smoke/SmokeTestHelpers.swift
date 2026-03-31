@testable import AgentRunKit
import Foundation
import Testing

struct SmokeAddParams: Codable, SchemaProviding {
    let lhs: Int
    let rhs: Int

    static var jsonSchema: JSONSchema {
        .object(
            properties: [
                "lhs": .integer(description: "First number"),
                "rhs": .integer(description: "Second number"),
            ],
            required: ["lhs", "rhs"]
        )
    }
}

struct SmokeAddOutput: Codable {
    let sum: Int
}

struct SmokeLookupParams: Codable, SchemaProviding {
    let key: String

    static var jsonSchema: JSONSchema {
        .object(
            properties: ["key": .string(description: "Lookup key")],
            required: ["key"]
        )
    }
}

struct SmokeLookupOutput: Codable {
    let value: String
}

struct SmokeWorkout: Codable, SchemaProviding {
    let exercises: [SmokeExercise]

    static var jsonSchema: JSONSchema {
        .object(
            properties: [
                "exercises": .array(items: SmokeExercise.jsonSchema),
            ],
            required: ["exercises"]
        )
    }
}

struct SmokeExercise: Codable, SchemaProviding {
    let name: String
    let sets: Int

    static var jsonSchema: JSONSchema {
        .object(
            properties: [
                "name": .string(description: "Exercise name"),
                "sets": .integer(description: "Number of sets"),
            ],
            required: ["name", "sets"]
        )
    }
}

let smokeWeatherTool = ToolDefinition(
    name: "get_weather",
    description: "Get the current weather for a city",
    parametersSchema: .object(
        properties: ["city": .string(description: "The city name")],
        required: ["city"]
    )
)

func makeSmokeAddTool() throws -> Tool<SmokeAddParams, SmokeAddOutput, EmptyContext> {
    try Tool(
        name: "add",
        description: "Add two numbers together. Always use this tool for addition.",
        executor: { params, _ in SmokeAddOutput(sum: params.lhs + params.rhs) }
    )
}

func makeSmokeVerboseLookupTool() throws -> Tool<SmokeLookupParams, SmokeLookupOutput, EmptyContext> {
    try Tool(
        name: "lookup",
        description: "Look up an entry by key. Always use this tool when asked to look something up.",
        executor: { params, _ in
            let padding = String(repeating: "x", count: 600)
            return SmokeLookupOutput(value: "Result for \(params.key): data_\(params.key)_\(padding)")
        }
    )
}

// MARK: - Assertions

func assertSmokeGenerate(client: any LLMClient) async throws {
    let messages: [ChatMessage] = [
        .system("You are a helpful assistant. Be concise."),
        .user("What is 2 + 2? Reply with just the number."),
    ]
    let response = try await client.generate(messages: messages, tools: [])
    #expect(!response.content.isEmpty)
    #expect(response.content.contains("4"))
    #expect(response.toolCalls.isEmpty)
}

func assertSmokeStream(client: any LLMClient) async throws {
    let messages: [ChatMessage] = [
        .system("You are a helpful assistant. Be concise."),
        .user("Count from 1 to 5, one number per line."),
    ]

    var contentChunks: [String] = []
    var finishedCount = 0

    for try await delta in client.stream(messages: messages, tools: []) {
        switch delta {
        case let .content(text):
            contentChunks.append(text)
        case .finished:
            finishedCount += 1
        default:
            break
        }
    }

    let fullContent = contentChunks.joined()
    #expect(!contentChunks.isEmpty)
    #expect(fullContent.contains("1"))
    #expect(fullContent.contains("5"))
    #expect(finishedCount >= 1)
}

func assertSmokeToolCall(client: any LLMClient) async throws {
    let messages: [ChatMessage] = [
        .system("You are a helpful assistant. Use tools when appropriate."),
        .user("What's the weather in Tokyo?"),
    ]

    let response = try await client.generate(messages: messages, tools: [smokeWeatherTool])

    #expect(response.toolCalls.count >= 1)
    let toolCall = response.toolCalls.first { $0.name == "get_weather" }
    #expect(toolCall != nil)
    #expect(toolCall?.arguments.lowercased().contains("tokyo") == true)
}

func assertSmokeStreamingToolCall(client: any LLMClient) async throws {
    let messages: [ChatMessage] = [
        .system("You are a helpful assistant. Use tools when appropriate."),
        .user("What's the weather in Paris?"),
    ]

    var toolCallStartName: String?
    var toolCallArgs: [Int: String] = [:]

    for try await delta in client.stream(messages: messages, tools: [smokeWeatherTool]) {
        switch delta {
        case let .toolCallStart(index, _, name):
            if name == "get_weather" {
                toolCallStartName = name
                toolCallArgs[index] = ""
            }
        case let .toolCallDelta(index, arguments):
            toolCallArgs[index, default: ""] += arguments
        default:
            break
        }
    }

    #expect(toolCallStartName == "get_weather")
    let allArgs = toolCallArgs.values.joined()
    #expect(allArgs.lowercased().contains("paris"))
}

func assertSmokeTokenUsage(client: any LLMClient) async throws {
    let messages: [ChatMessage] = [
        .system("You are a helpful assistant. Be concise."),
        .user("What is 2 + 2? Reply with just the number."),
    ]
    let response = try await client.generate(messages: messages, tools: [])
    #expect(response.tokenUsage != nil)
    #expect(response.tokenUsage?.input ?? 0 > 0)
    #expect(response.tokenUsage?.output ?? 0 > 0)
}

func assertSmokeStreamingTokenUsage(client: any LLMClient) async throws {
    let messages: [ChatMessage] = [
        .system("You are a helpful assistant. Be concise."),
        .user("What is 2 + 2? Reply with just the number."),
    ]

    var streamUsage: TokenUsage?

    for try await delta in client.stream(messages: messages, tools: []) {
        if case let .finished(usage) = delta {
            streamUsage = usage
        }
    }

    #expect(streamUsage != nil)
    #expect(streamUsage?.input ?? 0 > 0)
    #expect(streamUsage?.output ?? 0 > 0)
}

func assertSmokeStructuredOutput(client: any LLMClient) async throws {
    let chat = Chat<EmptyContext>(client: client)
    let (workout, history) = try await chat.send(
        "Give me exactly 2 upper body exercises",
        returning: SmokeWorkout.self
    )

    #expect(workout.exercises.count >= 2)
    for exercise in workout.exercises {
        #expect(!exercise.name.isEmpty)
        #expect(exercise.sets > 0)
    }
    #expect(history.count >= 2)
}

func assertSmokeAgentLoop(client: any LLMClient) async throws {
    let addTool = try makeSmokeAddTool()
    let config = AgentConfiguration(
        maxIterations: 5,
        systemPrompt: """
        You are a calculator assistant. When asked to add numbers, use the add tool.
        After getting the result, use the finish tool with the answer.
        """
    )

    let agent = Agent<EmptyContext>(client: client, tools: [addTool], configuration: config)
    let result = try await agent.run(userMessage: "What is 17 + 25?", context: EmptyContext())

    #expect(try requireContent(result).contains("42"))
    #expect(result.iterations >= 1)
}

func assertSmokeStreamingAgentLoop(client: any LLMClient) async throws {
    let addTool = try makeSmokeAddTool()
    let config = AgentConfiguration(
        maxIterations: 5,
        systemPrompt: """
        You are a calculator assistant. When asked to add numbers, use the add tool.
        After getting the result, use the finish tool with the answer.
        """
    )

    let agent = Agent<EmptyContext>(client: client, tools: [addTool], configuration: config)

    var toolStarted = false
    var toolCompleted = false
    var hasFinished = false
    var finishContent: String?

    for try await event in agent.stream(userMessage: "What is 7 + 8?", context: EmptyContext()) {
        switch event.kind {
        case .toolCallStarted:
            toolStarted = true
        case let .toolCallCompleted(_, name, result):
            if name == "add" {
                toolCompleted = true
                #expect(result.content.contains("15"))
            }
        case let .finished(_, content, _, _):
            hasFinished = true
            finishContent = content
        default:
            break
        }
    }

    #expect(toolStarted)
    #expect(toolCompleted)
    #expect(hasFinished)
    #expect(finishContent?.contains("15") == true)
}

func assertSmokeMultiTurn(client: any LLMClient) async throws {
    var messages: [ChatMessage] = [
        .system("You are a helpful assistant. Be concise."),
        .user("Remember the number 42."),
    ]

    let response1 = try await client.generate(messages: messages, tools: [])
    messages.append(.assistant(response1))
    messages.append(.user("What number did I ask you to remember?"))

    let response2 = try await client.generate(messages: messages, tools: [])
    #expect(response2.content.contains("42"))
}

func assertSmokeChatStreamWithTools(client: any LLMClient) async throws {
    let addTool = try makeSmokeAddTool()
    let chat = Chat<EmptyContext>(
        client: client,
        tools: [addTool],
        systemPrompt: "You are a calculator. Use the add tool for addition."
    )

    var deltas: [String] = []
    var toolStartedNames: [String] = []
    var toolCompletedResults: [(name: String, result: ToolResult)] = []
    var finishedEvent: StreamEvent?

    for try await event in chat.stream("What is 13 + 29?", context: EmptyContext()) {
        switch event.kind {
        case let .delta(text):
            deltas.append(text)
        case let .toolCallStarted(name, _):
            toolStartedNames.append(name)
        case let .toolCallCompleted(_, name, result):
            toolCompletedResults.append((name, result))
        case .finished:
            finishedEvent = event
        default:
            break
        }
    }

    #expect(toolStartedNames.contains("add"))

    let addResult = toolCompletedResults.first { $0.name == "add" }
    #expect(addResult != nil)
    #expect(addResult?.result.content.contains("42") == true)

    #expect(!deltas.joined().isEmpty)

    guard case let .finished(_, content, reason, history) = finishedEvent?.kind else {
        Issue.record("Expected .finished event")
        return
    }
    #expect(content == nil)
    #expect(reason == nil)
    #expect(history.count >= 4)
}

struct SmokeSubAgentParams: Codable, SchemaProviding {
    let task: String

    static var jsonSchema: JSONSchema {
        .object(
            properties: ["task": .string(description: "The task to delegate")],
            required: ["task"]
        )
    }
}

func makeSmokeSubAgentAddTool() throws -> Tool<SmokeAddParams, SmokeAddOutput, SubAgentContext<EmptyContext>> {
    try Tool(
        name: "add",
        description: "Add two numbers together. Always use this tool for addition.",
        executor: { params, _ in SmokeAddOutput(sum: params.lhs + params.rhs) }
    )
}

func assertSmokeSubAgentRoundTrip(client: any LLMClient) async throws {
    let addTool = try makeSmokeSubAgentAddTool()
    let childConfig = AgentConfiguration(
        maxIterations: 5,
        systemPrompt: """
        You are a calculator. When asked to add numbers, use the add tool.
        After getting the result, use the finish tool with the answer.
        """
    )
    let childAgent = Agent<SubAgentContext<EmptyContext>>(
        client: client, tools: [addTool], configuration: childConfig
    )

    let delegateTool: SubAgentTool<SmokeSubAgentParams, EmptyContext> = try SubAgentTool(
        name: "delegate_calculator",
        description: "Delegate a math question to the calculator sub-agent.",
        agent: childAgent,
        messageBuilder: { $0.task }
    )

    let parentConfig = AgentConfiguration(
        maxIterations: 5,
        systemPrompt: """
        You are a coordinator. You CANNOT do math yourself. \
        You MUST delegate ALL math questions to the delegate_calculator tool. \
        After receiving the result, use the finish tool.
        """
    )
    let parentAgent = Agent<SubAgentContext<EmptyContext>>(
        client: client, tools: [delegateTool], configuration: parentConfig
    )

    let result = try await parentAgent.run(
        userMessage: "What is 17 + 25?",
        context: SubAgentContext(inner: EmptyContext(), maxDepth: 3)
    )

    #expect(try requireContent(result).contains("42"))
    #expect(result.iterations >= 2)
}

func assertSmokeSubAgentStreamingEvents(client: any LLMClient) async throws {
    let addTool = try makeSmokeSubAgentAddTool()
    let childConfig = AgentConfiguration(
        maxIterations: 5,
        systemPrompt: """
        You are a calculator. When asked to add numbers, use the add tool.
        After getting the result, use the finish tool with the answer.
        """
    )
    let childAgent = Agent<SubAgentContext<EmptyContext>>(
        client: client, tools: [addTool], configuration: childConfig
    )

    let delegateTool: SubAgentTool<SmokeSubAgentParams, EmptyContext> = try SubAgentTool(
        name: "delegate_calculator",
        description: "Delegate a math question to the calculator sub-agent.",
        agent: childAgent,
        messageBuilder: { $0.task }
    )

    let parentConfig = AgentConfiguration(
        maxIterations: 5,
        systemPrompt: """
        You are a coordinator. You CANNOT do math yourself. \
        You MUST delegate ALL math questions to the delegate_calculator tool. \
        After receiving the result, use the finish tool.
        """
    )
    let parentAgent = Agent<SubAgentContext<EmptyContext>>(
        client: client, tools: [delegateTool], configuration: parentConfig
    )

    var events: [StreamEvent] = []
    for try await event in parentAgent.stream(
        userMessage: "What is 7 + 8?",
        context: SubAgentContext(inner: EmptyContext(), maxDepth: 3)
    ) {
        events.append(event)
    }

    let startedIndex = events.firstIndex {
        if case let .subAgentStarted(_, toolName) = $0.kind { toolName == "delegate_calculator" } else { false }
    }
    let completedIndex = events.firstIndex {
        if case let .subAgentCompleted(_, toolName, result) = $0.kind {
            toolName == "delegate_calculator" && result.content.contains("15")
        } else {
            false
        }
    }
    let hasFinished = events.contains {
        if case .finished = $0.kind { true } else { false }
    }

    guard let start = startedIndex, let completed = completedIndex else {
        Issue.record("Expected both subAgentStarted and subAgentCompleted events")
        return
    }
    #expect(start < completed)
    #expect(hasFinished)
}

func assertSmokeSubAgentHistoryInheritance(client: any LLMClient) async throws {
    let childConfig = AgentConfiguration(
        maxIterations: 3,
        systemPrompt: "Answer questions using the conversation history. Be concise."
    )
    let childAgent = Agent<SubAgentContext<EmptyContext>>(
        client: client, tools: [], configuration: childConfig
    )

    let delegateTool: SubAgentTool<SmokeSubAgentParams, EmptyContext> = try SubAgentTool(
        name: "delegate_recall",
        description: "Delegate a question to the sub-agent that can see conversation history.",
        agent: childAgent,
        inheritParentMessages: true,
        messageBuilder: { $0.task }
    )

    let parentConfig = AgentConfiguration(
        maxIterations: 5,
        systemPrompt: "You are a coordinator. Use the delegate_recall tool to ask the sub-agent questions."
    )
    let parentAgent = Agent<SubAgentContext<EmptyContext>>(
        client: client, tools: [delegateTool], configuration: parentConfig
    )

    let result = try await parentAgent.run(
        userMessage: """
        The secret codeword is xylophone7. \
        Ask the sub-agent what the secret codeword is.
        """,
        context: SubAgentContext(inner: EmptyContext(), maxDepth: 3)
    )

    #expect(try requireContent(result).lowercased().contains("xylophone7"))
}

struct SmokeAuthor: Codable, SchemaProviding {
    let name: String
    let birthYear: Int?

    static var jsonSchema: JSONSchema {
        .object(
            properties: [
                "name": .string(description: "Author name"),
                "birthYear": .integer(description: "Birth year").optional(),
            ],
            required: ["name", "birthYear"]
        )
    }
}

struct SmokeBookReview: Codable, SchemaProviding {
    let title: String
    let author: SmokeAuthor
    let rating: Int
    let tags: [String]
    let sequel: String?

    static var jsonSchema: JSONSchema {
        .object(
            properties: [
                "title": .string(description: "Book title"),
                "author": SmokeAuthor.jsonSchema,
                "rating": .integer(description: "Rating 1-5"),
                "tags": .array(items: .string()),
                "sequel": .string(description: "Sequel title if any").optional(),
            ],
            required: ["title", "author", "rating", "tags", "sequel"]
        )
    }
}

func assertSmokeNestedStructuredOutput(client: any LLMClient) async throws {
    let chat = Chat<EmptyContext>(client: client)
    let (review, history) = try await chat.send(
        "Write a short review of '1984' by George Orwell. Rate it 1-5. Include at least 2 tags.",
        returning: SmokeBookReview.self
    )

    #expect(!review.title.isEmpty)
    #expect(!review.author.name.isEmpty)
    #expect(review.rating >= 1 && review.rating <= 5)
    #expect(review.tags.count >= 2)
    #expect(history.count >= 2)
}

func assertSmokeReasoningGenerate(client: any LLMClient) async throws {
    let messages: [ChatMessage] = [
        .system("You are a helpful assistant."),
        .user("What is 5 + 7?"),
    ]

    let response = try await client.generate(messages: messages, tools: [])
    #expect(response.content.contains("12"))
    #expect(response.tokenUsage != nil)
    #expect(response.reasoning != nil)
}

func assertSmokeReasoningStream(client: any LLMClient) async throws {
    let messages: [ChatMessage] = [
        .system("You are a helpful assistant. Think step by step."),
        .user("What is 17 * 23? Show your reasoning."),
    ]

    var contentChunks: [String] = []
    var reasoningChunks: [String] = []
    var hasFinished = false

    for try await delta in client.stream(messages: messages, tools: []) {
        switch delta {
        case let .content(text):
            contentChunks.append(text)
        case let .reasoning(text):
            reasoningChunks.append(text)
        case .finished:
            hasFinished = true
        default:
            break
        }
    }

    let fullContent = contentChunks.joined()
    #expect(hasFinished)
    #expect(fullContent.contains("391"))
    #expect(!reasoningChunks.isEmpty)
}

// MARK: - Context Management Assertions

func assertSmokeObservationPruning(client: any LLMClient) async throws {
    let lookupTool = try makeSmokeVerboseLookupTool()
    let config = AgentConfiguration(
        maxIterations: 10,
        systemPrompt: """
        You are a lookup assistant. When asked to look up multiple items, \
        look them up one at a time in sequence using the lookup tool. \
        After all lookups are done, summarize the results using the finish tool.
        """,
        compactionThreshold: 0.5
    )

    let agent = Agent<EmptyContext>(client: client, tools: [lookupTool], configuration: config)
    let result = try await agent.run(
        userMessage: "Look up alpha, then look up beta, then look up gamma. Summarize all results.",
        context: EmptyContext()
    )

    let content = try requireContent(result)
    #expect(!content.isEmpty)
    #expect(result.iterations >= 3)

    let hasPruned = result.history.contains { message in
        if case let .tool(_, _, content) = message {
            return content.contains("(pruned)")
        }
        return false
    }
    #expect(hasPruned)
}

func assertSmokeLLMSummarization(client: any LLMClient) async throws {
    let addTool = try makeSmokeAddTool()
    let config = AgentConfiguration(
        maxIterations: 15,
        systemPrompt: """
        You are a calculator assistant. When asked to add numbers, use the add tool. \
        Perform each addition one at a time in sequence. Never batch multiple additions. \
        After all additions, report every result using the finish tool.
        """,
        compactionThreshold: 0.3
    )

    let agent = Agent<EmptyContext>(client: client, tools: [addTool], configuration: config)
    let result = try await agent.run(
        userMessage: """
        Add 1+2, then add 3+4, then add 5+6, then add 7+8, then add 9+10. \
        Report all five results.
        """,
        context: EmptyContext()
    )

    let content = try requireContent(result)
    #expect(!content.isEmpty)
    let hasContinuation = result.history.contains { message in
        if case let .user(content) = message {
            return content.contains("[Context Continuation]")
        }
        return false
    }
    #expect(hasContinuation)
}

func assertSmokeToolResultTruncation(client: any LLMClient) async throws {
    let lookupTool = try makeSmokeVerboseLookupTool()
    let config = AgentConfiguration(
        maxIterations: 5,
        systemPrompt: """
        You are a lookup assistant. Use the lookup tool when asked to look something up. \
        After getting the result, report it using the finish tool.
        """,
        maxToolResultCharacters: 100
    )

    let agent = Agent<EmptyContext>(client: client, tools: [lookupTool], configuration: config)
    let result = try await agent.run(
        userMessage: "Look up the entry for alpha.",
        context: EmptyContext()
    )

    let hasTruncated = result.history.contains { message in
        if case let .tool(_, _, content) = message {
            return content.contains("...[truncated]...")
        }
        return false
    }
    #expect(hasTruncated)
}

func assertSmokeMaxMessages(client: any LLMClient) async throws {
    let addTool = try makeSmokeAddTool()
    let config = AgentConfiguration(
        maxIterations: 10,
        systemPrompt: """
        You are a calculator assistant. When asked to add numbers, use the add tool. \
        Perform each addition one at a time in sequence. \
        After all additions, report the last result using the finish tool.
        """,
        maxMessages: 6
    )

    let agent = Agent<EmptyContext>(client: client, tools: [addTool], configuration: config)
    let result = try await agent.run(
        userMessage: "Add 1+1, then add 2+2, then add 3+3. Report the last result.",
        context: EmptyContext()
    )

    let hasSystem = result.history.contains { $0.isSystem }
    #expect(hasSystem)
    #expect(result.history.count <= 8)
}

func assertSmokeBudgetEvents(client: any LLMClient) async throws {
    let addTool = try makeSmokeAddTool()
    let config = AgentConfiguration(
        maxIterations: 5,
        systemPrompt: """
        You are a calculator assistant. When asked to add numbers, use the add tool. \
        After getting the result, report it using the finish tool.
        """,
        contextBudget: ContextBudgetConfig(softThreshold: 0.3)
    )

    let agent = Agent<EmptyContext>(client: client, tools: [addTool], configuration: config)

    var budgetUpdatedCount = 0
    var budgetAdvisoryCount = 0

    for try await event in agent.stream(userMessage: "What is 10 + 20?", context: EmptyContext()) {
        switch event.kind {
        case .budgetUpdated:
            budgetUpdatedCount += 1
        case .budgetAdvisory:
            budgetAdvisoryCount += 1
        default:
            break
        }
    }

    #expect(budgetUpdatedCount >= 1)
    #expect(budgetAdvisoryCount >= 1)
}

func assertSmokeIterationCompleted(client: any LLMClient) async throws {
    let addTool = try makeSmokeAddTool()
    let config = AgentConfiguration(
        maxIterations: 5,
        systemPrompt: """
        You are a calculator assistant. When asked to add numbers, use the add tool. \
        After getting the result, report it using the finish tool.
        """
    )

    let agent = Agent<EmptyContext>(client: client, tools: [addTool], configuration: config)

    var iterationEvents: [(usage: TokenUsage, iteration: Int)] = []

    for try await event in agent.stream(userMessage: "What is 10 + 20?", context: EmptyContext()) {
        if case let .iterationCompleted(usage, iteration) = event.kind {
            iterationEvents.append((usage, iteration))
        }
    }

    #expect(iterationEvents.count >= 2)
    for event in iterationEvents {
        #expect(event.usage.input > 0)
    }
}

private actor SmokeApprovalTracker {
    var callCount = 0
    var lastToolName: String?

    func record(_ toolName: String) {
        callCount += 1
        lastToolName = toolName
    }
}

func assertSmokeApprovalGate(client: any LLMClient) async throws {
    let addTool = try makeSmokeAddTool()
    let config = AgentConfiguration(
        maxIterations: 5,
        systemPrompt: """
        You are a calculator assistant. When asked to add numbers, use the add tool.
        After getting the result, use the finish tool with the answer.
        """,
        approvalPolicy: .allTools
    )

    let tracker = SmokeApprovalTracker()

    let agent = Agent<EmptyContext>(client: client, tools: [addTool], configuration: config)
    let result = try await agent.run(
        userMessage: "What is 17 + 25?",
        context: EmptyContext(),
        approvalHandler: { request in
            await tracker.record(request.toolName)
            return .approve
        }
    )

    let callCount = await tracker.callCount
    let toolName = await tracker.lastToolName
    #expect(callCount >= 1)
    #expect(toolName == "add")
    #expect(try requireContent(result).contains("42"))
    #expect(result.iterations >= 2)
}

func assertSmokeApprovalDenial(client: any LLMClient) async throws {
    let addTool = try makeSmokeAddTool()
    let config = AgentConfiguration(
        maxIterations: 5,
        systemPrompt: """
        You are a calculator assistant. When asked to add numbers, use the add tool.
        If a tool call is denied, explain that you cannot perform the calculation and finish.
        """,
        approvalPolicy: .allTools
    )

    let tracker = SmokeApprovalTracker()

    let agent = Agent<EmptyContext>(client: client, tools: [addTool], configuration: config)
    let result = try await agent.run(
        userMessage: "What is 17 + 25?",
        context: EmptyContext(),
        approvalHandler: { request in
            await tracker.record(request.toolName)
            return .deny(reason: "Calculations are disabled.")
        }
    )

    let callCount = await tracker.callCount
    #expect(callCount >= 1)
    let content = try requireContent(result)
    #expect(!content.isEmpty)
    let denialInHistory = result.history.contains { message in
        if case let .tool(_, _, content) = message {
            return content.contains("disabled")
        }
        return false
    }
    #expect(denialInHistory)
}

func assertSmokeStreamingApproval(client: any LLMClient) async throws {
    let addTool = try makeSmokeAddTool()
    let config = AgentConfiguration(
        maxIterations: 5,
        systemPrompt: """
        You are a calculator assistant. When asked to add numbers, use the add tool.
        After getting the result, use the finish tool with the answer.
        """,
        approvalPolicy: .allTools
    )

    let agent = Agent<EmptyContext>(client: client, tools: [addTool], configuration: config)

    var approvalRequested = false
    var approvalResolved = false
    var toolCompleted = false
    var finishContent: String?

    for try await event in agent.stream(
        userMessage: "What is 7 + 8?",
        context: EmptyContext(),
        approvalHandler: { request in
            #expect(request.toolName == "add")
            return .approve
        }
    ) {
        switch event.kind {
        case .toolApprovalRequested:
            approvalRequested = true
        case .toolApprovalResolved:
            approvalResolved = true
        case let .toolCallCompleted(_, name, result):
            if name == "add" {
                toolCompleted = true
                #expect(result.content.contains("15"))
            }
        case let .finished(_, content, _, _):
            finishContent = content
        default:
            break
        }
    }

    #expect(approvalRequested)
    #expect(approvalResolved)
    #expect(toolCompleted)
    #expect(finishContent?.contains("15") == true)
}
