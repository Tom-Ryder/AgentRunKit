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
    try smokeExpect(!response.content.isEmpty)
    try smokeExpect(response.content.contains("4"))
    try smokeExpect(response.toolCalls.isEmpty)
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
    try smokeExpect(!contentChunks.isEmpty)
    try smokeExpect(fullContent.contains("1"))
    try smokeExpect(fullContent.contains("5"))
    try smokeExpect(finishedCount >= 1)
}

func assertSmokeToolCall(client: any LLMClient) async throws {
    let messages: [ChatMessage] = [
        .system("You are a helpful assistant. Use tools when appropriate."),
        .user("What's the weather in Tokyo?"),
    ]

    let response = try await client.generate(messages: messages, tools: [smokeWeatherTool])

    try smokeExpect(response.toolCalls.count >= 1)
    let toolCall = response.toolCalls.first { $0.name == "get_weather" }
    try smokeExpect(toolCall != nil)
    try smokeExpect(toolCall?.arguments.lowercased().contains("tokyo") == true)
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
        case let .toolCallStart(index, _, name, _):
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

    try smokeExpect(toolCallStartName == "get_weather")
    let allArgs = toolCallArgs.values.joined()
    try smokeExpect(allArgs.lowercased().contains("paris"))
}

func assertSmokeTokenUsage(client: any LLMClient) async throws {
    let messages: [ChatMessage] = [
        .system("You are a helpful assistant. Be concise."),
        .user("What is 2 + 2? Reply with just the number."),
    ]
    let response = try await client.generate(messages: messages, tools: [])
    try smokeExpect(response.tokenUsage != nil)
    try smokeExpect(response.tokenUsage?.input ?? 0 > 0)
    try smokeExpect(response.tokenUsage?.output ?? 0 > 0)
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

    try smokeExpect(streamUsage != nil)
    try smokeExpect(streamUsage?.input ?? 0 > 0)
    try smokeExpect(streamUsage?.output ?? 0 > 0)
}

func assertSmokeStructuredOutput(client: any LLMClient) async throws {
    let workout = try await sendSmokeStructuredOutput(
        "Give me exactly 2 upper body exercises",
        client: client,
        returning: SmokeWorkout.self
    )

    try smokeExpect(workout.exercises.count >= 2)
    for exercise in workout.exercises {
        try smokeExpect(!exercise.name.isEmpty)
        try smokeExpect(exercise.sets > 0)
    }
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

    try smokeExpect(requireContent(result).contains("42"))
    try smokeExpect(result.iterations >= 1)
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
                try smokeExpect(result.content.contains("15"))
            }
        case let .finished(_, content, _, _):
            hasFinished = true
            finishContent = content
        default:
            break
        }
    }

    try smokeExpect(toolStarted)
    try smokeExpect(toolCompleted)
    try smokeExpect(hasFinished)
    try smokeExpect(finishContent?.contains("15") == true)
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
    try smokeExpect(response2.content.contains("42"))
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

    try smokeExpect(toolStartedNames.contains("add"))

    let addResult = toolCompletedResults.first { $0.name == "add" }
    try smokeExpect(addResult != nil)
    try smokeExpect(addResult?.result.content.contains("42") == true)

    try smokeExpect(!deltas.joined().isEmpty)

    guard case let .finished(_, content, reason, history) = finishedEvent?.kind else {
        try smokeFail("Expected .finished event")
    }
    try smokeExpect(content == nil)
    try smokeExpect(reason == nil)
    try smokeExpect(history.count >= 4)
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

    try smokeExpect(requireContent(result).contains("42"))
    try smokeExpect(result.iterations >= 2)
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
        try smokeFail("Expected both subAgentStarted and subAgentCompleted events")
    }
    try smokeExpect(start < completed)
    try smokeExpect(hasFinished)
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

    try smokeExpect(requireContent(result).lowercased().contains("xylophone7"))
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
    let review = try await sendSmokeStructuredOutput(
        """
        Return a book review object with these exact fields:
        title: 1984
        author.name: George Orwell
        author.birthYear: 1903
        rating: 5
        tags: classic, dystopian
        sequel: null
        """,
        client: client,
        returning: SmokeBookReview.self
    )

    try smokeExpect(review.title == "1984")
    try smokeExpect(review.author.name == "George Orwell")
    try smokeExpect(review.author.birthYear == 1903)
    try smokeExpect(review.rating == 5)
    try smokeExpect(review.tags.contains("classic"))
    try smokeExpect(review.tags.contains("dystopian"))
    try smokeExpect(review.sequel == nil)
}

func assertSmokeReasoningGenerate(client: any LLMClient) async throws {
    let messages: [ChatMessage] = [
        .system("You are a helpful assistant."),
        .user("What is 5 + 7?"),
    ]

    let response = try await client.generate(messages: messages, tools: [])
    try smokeExpect(response.content.contains("12"))
    try smokeExpect(response.tokenUsage != nil)
    try smokeExpect(response.reasoning != nil)
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
    try smokeExpect(hasFinished)
    try smokeExpect(fullContent.contains("391"))
    try smokeExpect(!reasoningChunks.isEmpty)
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
    try smokeExpect(!content.isEmpty)
    try smokeExpect(result.iterations >= 3)

    let hasPruned = result.history.contains { message in
        if case let .tool(_, _, content) = message {
            return content.contains("(pruned)")
        }
        return false
    }
    try smokeExpect(hasPruned)
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
    try smokeExpect(!content.isEmpty)
    let hasContinuation = result.history.contains { message in
        if case let .user(content) = message {
            return content.contains("[Context Continuation]")
        }
        return false
    }
    try smokeExpect(hasContinuation)
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

    let fullOutput = SmokeLookupOutput(
        value: "Result for alpha: data_alpha_\(String(repeating: "x", count: 600))"
    )
    let fullContent = try smokeRequire(String(data: JSONEncoder().encode(fullOutput), encoding: .utf8))
    let hasTruncated = result.history.contains { message in
        if case let .tool(_, _, content) = message {
            return content.count <= 100 && content != fullContent
        }
        return false
    }
    try smokeExpect(hasTruncated)
}

func assertSmokeMaxMessages(client: any LLMClient) async throws {
    let addTool = try makeSmokeAddTool()
    let oldestPrompt = "Historical note alpha."
    let droppedPrompt = "Historical note beta."
    let retainedPrompt = "Historical note gamma."
    let seededHistory: [ChatMessage] = [
        .user(oldestPrompt),
        .assistant(AssistantMessage(content: "Noted alpha.")),
        .user(droppedPrompt),
        .assistant(AssistantMessage(content: "Noted beta.")),
        .user(retainedPrompt),
        .assistant(AssistantMessage(content: "Noted gamma.")),
    ]
    let config = AgentConfiguration(
        maxIterations: 10,
        systemPrompt: """
        You are a calculator assistant. When asked to add numbers, use the add tool. \
        After all additions, report the last result using the finish tool.
        """,
        maxMessages: 3
    )

    let agent = Agent<EmptyContext>(client: client, tools: [addTool], configuration: config)
    let result = try await agent.run(
        userMessage: "What is 2 + 2? Report the last result.",
        history: seededHistory,
        context: EmptyContext()
    )

    let hasSystem = result.history.contains { $0.isSystem }
    let retainedOldestPrompt = result.history.contains { message in
        guard case let .user(content) = message else { return false }
        return content == oldestPrompt
    }
    let retainedDroppedPrompt = result.history.contains { message in
        guard case let .user(content) = message else { return false }
        return content == droppedPrompt
    }
    let addResultRetained = result.history.contains { message in
        guard case let .tool(_, name, content) = message else { return false }
        return name == "add" && content.contains("4")
    }
    try smokeExpect(hasSystem)
    try smokeExpect(!retainedOldestPrompt)
    try smokeExpect(!retainedDroppedPrompt)
    try smokeExpect(addResultRetained)
    try result.history.validateForAgentHistory()
}

func assertSmokeBudgetEvents(client: any LLMClient) async throws {
    let addTool = try makeSmokeAddTool()
    let padding = Array(
        repeating: "This sentence exists to exercise context budget handling.",
        count: 24
    ).joined(separator: " ")
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

    for try await event in agent.stream(
        userMessage: """
        \(padding)

        What is 10 + 20? Use the add tool and then report the result using the finish tool.
        """,
        context: EmptyContext()
    ) {
        switch event.kind {
        case .budgetUpdated:
            budgetUpdatedCount += 1
        case .budgetAdvisory:
            budgetAdvisoryCount += 1
        default:
            break
        }
    }

    try smokeExpect(budgetUpdatedCount >= 1)
    try smokeExpect(budgetAdvisoryCount >= 1)
}

func assertSmokeBudgetHistoryIntegrity(client: any LLMClient) async throws {
    let addTool = try makeSmokeAddTool()
    let config = AgentConfiguration(
        maxIterations: 5,
        systemPrompt: """
        You are a calculator assistant. When asked to add numbers, use the add tool. \
        After getting the result, report it using the finish tool.
        """,
        contextBudget: ContextBudgetConfig(softThreshold: 0.25, enableVisibility: true)
    )

    let agent = Agent<EmptyContext>(client: client, tools: [addTool], configuration: config)

    var budgetUpdatedCount = 0
    var budgetAdvisoryCount = 0
    var toolCompleted = false
    var finishContent: String?

    for try await event in agent.stream(userMessage: "What is 7 + 8?", context: EmptyContext()) {
        switch event.kind {
        case .budgetUpdated:
            budgetUpdatedCount += 1
        case .budgetAdvisory:
            budgetAdvisoryCount += 1
        case let .toolCallCompleted(_, name, result):
            if name == "add" {
                toolCompleted = true
                try smokeExpect(result.content.contains("15"))
            }
        case let .finished(_, content, _, _):
            finishContent = content
        default:
            break
        }
    }

    try smokeExpect(toolCompleted)
    try smokeExpect(budgetUpdatedCount >= 1)
    try smokeExpect(budgetAdvisoryCount >= 1)
    try smokeExpect(finishContent?.contains("15") == true)
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
        if case let .iterationCompleted(usage, iteration, history) = event.kind {
            try iterationEvents.append((smokeRequire(usage), iteration))
            try smokeExpect(!history.isEmpty)
        }
    }

    try smokeExpect(iterationEvents.count >= 2)
    for event in iterationEvents {
        try smokeExpect(event.usage.input > 0)
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
    try smokeExpect(callCount >= 1)
    try smokeExpect(toolName == "add")
    try smokeExpect(requireContent(result).contains("42"))
    try smokeExpect(result.iterations >= 2)
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
    try smokeExpect(callCount >= 1)
    let toolMessages = result.history.compactMap { message -> String? in
        if case let .tool(_, _, content) = message {
            return content
        }
        return nil
    }
    try smokeExpect(!toolMessages.isEmpty)
    let denialMessages = toolMessages.filter { $0.contains("disabled") }
    try smokeExpect(denialMessages.count == callCount)
    try smokeExpect(!toolMessages.contains { $0.contains(#""sum""#) })
    if let content = result.content {
        try smokeExpect(!content.isEmpty)
    }
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

    let tracker = SmokeApprovalTracker()
    var approvalRequested = false
    var approvalResolved = false
    var toolCompleted = false
    var finishContent: String?

    for try await event in agent.stream(
        userMessage: "What is 7 + 8?",
        context: EmptyContext(),
        approvalHandler: { request in
            await tracker.record(request.toolName)
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
                try smokeExpect(result.content.contains("15"))
            }
        case let .finished(_, content, _, _):
            finishContent = content
        default:
            break
        }
    }

    let approvalToolName = await tracker.lastToolName
    try smokeExpect(approvalRequested)
    try smokeExpect(approvalResolved)
    try smokeExpect(approvalToolName == "add")
    try smokeExpect(toolCompleted)
    try smokeExpect(finishContent?.contains("15") == true)
}
