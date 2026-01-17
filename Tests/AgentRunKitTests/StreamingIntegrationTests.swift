import Foundation
import Testing

@testable import AgentRunKit

private let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? ""
private let hasAPIKey = !apiKey.isEmpty
private let defaultModel = "google/gemini-3-flash-preview"

@Suite(.enabled(if: hasAPIKey, "Requires OPENROUTER_API_KEY environment variable"))
struct StreamingIntegrationTests {
    let client = OpenAIClient(
        apiKey: apiKey,
        model: defaultModel,
        maxTokens: 1024,
        baseURL: OpenAIClient.openRouterBaseURL
    )

    @Test
    func clientStreamingWorks() async throws {
        let messages: [ChatMessage] = [
            .system("You are a helpful assistant. Be concise."),
            .user("Count from 1 to 5, one number per line.")
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
        #expect(!contentChunks.isEmpty, "Should receive content")
        #expect(fullContent.contains("1"))
        #expect(fullContent.contains("5"))
        #expect(finishedCount == 1, "Should receive exactly one finished event")
    }

    @Test
    func clientStreamingWithToolCalls() async throws {
        let weatherTool = ToolDefinition(
            name: "get_weather",
            description: "Get the current weather for a city",
            parametersSchema: .object(
                properties: ["city": .string(description: "The city name")],
                required: ["city"]
            )
        )

        let messages: [ChatMessage] = [
            .system("You are a helpful assistant. Use tools when appropriate."),
            .user("What's the weather in Paris?")
        ]

        var toolCallStartName: String?
        var toolCallStartIndex: Int?
        var toolCallArgs: [Int: String] = [:]

        for try await delta in client.stream(messages: messages, tools: [weatherTool]) {
            switch delta {
            case let .toolCallStart(index, _, name):
                if name == "get_weather" {
                    toolCallStartName = name
                    toolCallStartIndex = index
                }
            case let .toolCallDelta(index, arguments):
                toolCallArgs[index, default: ""] += arguments
            default:
                break
            }
        }

        #expect(toolCallStartName == "get_weather", "Should call get_weather tool")

        if let index = toolCallStartIndex {
            let args = toolCallArgs[index] ?? ""
            #expect(args.lowercased().contains("paris"), "Tool args should contain Paris")
        }
    }

    @Test
    func agentStreamingCompletesWithFinishTool() async throws {
        let agent = Agent<EmptyContext>(client: client, tools: [])

        var events: [StreamEvent] = []
        for try await event in agent.stream(
            userMessage: "Say 'Hello World' and finish. Use the finish tool.",
            context: EmptyContext()
        ) {
            events.append(event)
        }

        let deltas = events.compactMap { event -> String? in
            if case let .delta(text) = event { return text }
            return nil
        }

        let hasFinished = events.contains { event in
            if case .finished = event { return true }
            return false
        }

        #expect(!deltas.isEmpty || hasFinished, "Should receive content or finish")
        #expect(hasFinished, "Should receive finished event")
    }

    @Test
    func agentStreamingWithToolExecution() async throws {
        let addTool = try Tool<StreamingAddParams, StreamingAddOutput, EmptyContext>(
            name: "add",
            description: "Add two numbers together",
            executor: { params, _ in StreamingAddOutput(sum: params.lhs + params.rhs) }
        )

        let config = AgentConfiguration(
            maxIterations: 5,
            systemPrompt: """
            You are a calculator. Use add tool for addition, then finish with the result.
            """
        )

        let agent = Agent<EmptyContext>(client: client, tools: [addTool], configuration: config)

        var toolStarted = false
        var toolCompleted = false
        var hasFinished = false

        for try await event in agent.stream(
            userMessage: "What is 7 + 8?",
            context: EmptyContext()
        ) {
            switch event {
            case .toolCallStarted:
                toolStarted = true
            case let .toolCallCompleted(_, name, result):
                if name == "add" {
                    toolCompleted = true
                    #expect(result.content.contains("15"), "Add result should contain 15")
                }
            case .finished:
                hasFinished = true
            default:
                break
            }
        }

        #expect(toolStarted, "Should emit toolCallStarted event")
        #expect(toolCompleted, "Should emit toolCallCompleted event")
        #expect(hasFinished, "Should emit finished event")
    }

    @Test
    func chatStreamingWithTools() async throws {
        let echoTool = try Tool<StreamingEchoParams, StreamingEchoOutput, EmptyContext>(
            name: "echo",
            description: "Echo back the message",
            executor: { params, _ in StreamingEchoOutput(echoed: "Echo: \(params.message)") }
        )

        let chat = Chat<EmptyContext>(
            client: client,
            tools: [echoTool],
            systemPrompt: "You are a helpful assistant. Use the echo tool when asked to echo something."
        )

        var events: [StreamEvent] = []
        for try await event in chat.stream("Echo the word 'test'", context: EmptyContext()) {
            events.append(event)
        }

        let hasFinished = events.contains { if case .finished = $0 { return true }; return false }
        #expect(hasFinished, "Should finish successfully")

        let toolCompleted = events.first { event in
            if case let .toolCallCompleted(_, name, _) = event { return name == "echo" }
            return false
        }
        #expect(toolCompleted != nil, "Should execute echo tool")
    }
}

private struct StreamingAddParams: Codable, SchemaProviding, Sendable {
    let lhs: Int
    let rhs: Int

    static var jsonSchema: JSONSchema {
        .object(
            properties: [
                "lhs": .integer(description: "First number"),
                "rhs": .integer(description: "Second number")
            ],
            required: ["lhs", "rhs"]
        )
    }
}

private struct StreamingAddOutput: Codable, Sendable {
    let sum: Int
}

private struct StreamingEchoParams: Codable, SchemaProviding, Sendable {
    let message: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string(description: "Message to echo")], required: ["message"])
    }
}

private struct StreamingEchoOutput: Codable, Sendable {
    let echoed: String
}

@Suite(.enabled(if: hasAPIKey, "Requires OPENROUTER_API_KEY environment variable"))
struct ReasoningIntegrationTests {
    @Test
    func streamingWithReasoningConfigWorks() async throws {
        let client = OpenAIClient(
            apiKey: apiKey,
            model: defaultModel,
            maxTokens: 2048,
            baseURL: OpenAIClient.openRouterBaseURL,
            reasoningConfig: .medium
        )

        let messages: [ChatMessage] = [
            .system("You are a helpful assistant. Think step by step."),
            .user("What is 17 * 23? Show your reasoning.")
        ]

        var reasoningChunks: [String] = []
        var contentChunks: [String] = []
        var hasFinished = false

        for try await delta in client.stream(messages: messages, tools: []) {
            switch delta {
            case let .reasoning(text):
                reasoningChunks.append(text)
            case let .content(text):
                contentChunks.append(text)
            case .finished:
                hasFinished = true
            default:
                break
            }
        }

        let fullContent = contentChunks.joined()

        #expect(hasFinished, "Should receive finished event")
        #expect(fullContent.contains("391"), "Answer should contain 391")

        if !reasoningChunks.isEmpty {
            let fullReasoning = reasoningChunks.joined()
            #expect(fullReasoning.count > 10, "Reasoning should have substantial content")
        }
    }

    @Test
    func agentStreamingAccumulatesReasoningInHistory() async throws {
        let client = OpenAIClient(
            apiKey: apiKey,
            model: defaultModel,
            maxTokens: 2048,
            baseURL: OpenAIClient.openRouterBaseURL,
            reasoningConfig: .low
        )

        let config = AgentConfiguration(
            maxIterations: 3,
            systemPrompt: """
            You are a calculator assistant. Answer math questions directly.
            After computing the answer, immediately use the finish tool with the result.
            """
        )

        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)

        var reasoningDeltas: [String] = []
        var finalHistory: [ChatMessage] = []

        for try await event in agent.stream(
            userMessage: "What is 12 + 15? Use the finish tool with the answer.",
            context: EmptyContext()
        ) {
            switch event {
            case let .reasoningDelta(text):
                reasoningDeltas.append(text)
            case let .finished(_, _, _, history):
                finalHistory = history
            default:
                break
            }
        }

        #expect(!finalHistory.isEmpty, "Should have history")

        let assistantMessages = finalHistory.compactMap { msg -> AssistantMessage? in
            if case let .assistant(assistant) = msg { return assistant }
            return nil
        }

        #expect(!assistantMessages.isEmpty, "Should have assistant message in history")

        if !reasoningDeltas.isEmpty {
            let accumulatedReasoning = reasoningDeltas.joined()
            let historyReasoning = assistantMessages.first?.reasoning?.content ?? ""
            #expect(historyReasoning == accumulatedReasoning,
                    "History reasoning should match accumulated deltas")
        }
    }

    @Test
    func nonStreamingReasoningParsesCorrectly() async throws {
        let client = OpenAIClient(
            apiKey: apiKey,
            model: defaultModel,
            maxTokens: 2048,
            baseURL: OpenAIClient.openRouterBaseURL,
            reasoningConfig: .low
        )

        let messages: [ChatMessage] = [
            .system("You are a helpful assistant."),
            .user("What is 5 + 7?")
        ]

        let response = try await client.generate(messages: messages, tools: [])

        #expect(response.content.contains("12"), "Response should contain 12")
        #expect(response.tokenUsage != nil, "Should have token usage")
    }

    @Test
    func reasoningConfigEncodesInRequest() async throws {
        let client = OpenAIClient(
            apiKey: apiKey,
            model: defaultModel,
            maxTokens: 1024,
            baseURL: OpenAIClient.openRouterBaseURL,
            reasoningConfig: .high
        )

        let messages: [ChatMessage] = [
            .user("Hello")
        ]

        let response = try await client.generate(messages: messages, tools: [])

        #expect(!response.content.isEmpty, "Should get a response")
    }
}
