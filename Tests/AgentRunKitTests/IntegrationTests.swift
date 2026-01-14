import Foundation
import Testing

@testable import AgentRunKit

private let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? ""
private let hasAPIKey = !apiKey.isEmpty
private let defaultModel = "google/gemini-3-flash-preview"

@Suite(.enabled(if: hasAPIKey, "Requires OPENROUTER_API_KEY environment variable"))
struct OpenAIClientIntegrationTests {
    let client = OpenAIClient(
        apiKey: apiKey,
        model: defaultModel,
        maxTokens: 1024,
        baseURL: OpenAIClient.openRouterBaseURL
    )

    @Test
    func basicCompletion() async throws {
        let messages: [ChatMessage] = [
            .system("You are a helpful assistant. Be concise."),
            .user("What is 2 + 2? Reply with just the number.")
        ]

        let response = try await client.generate(messages: messages, tools: [])

        #expect(!response.content.isEmpty)
        #expect(response.content.contains("4"))
        #expect(response.tokenUsage?.input ?? 0 > 0)
        #expect(response.tokenUsage?.output ?? 0 > 0)
    }

    @Test
    func toolCallingRoundTrip() async throws {
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
            .user("What's the weather in Tokyo?")
        ]

        let response = try await client.generate(messages: messages, tools: [weatherTool])

        #expect(response.toolCalls.count >= 1)
        let toolCall = response.toolCalls.first { $0.name == "get_weather" }
        #expect(toolCall != nil)
        #expect(toolCall?.arguments.contains("Tokyo") == true || toolCall?.arguments.contains("tokyo") == true)
    }

    @Test
    func multiTurnConversation() async throws {
        var messages: [ChatMessage] = [
            .system("You are a helpful assistant. Be concise."),
            .user("Remember the number 42.")
        ]

        let response1 = try await client.generate(messages: messages, tools: [])
        messages.append(.assistant(response1))
        messages.append(.user("What number did I ask you to remember?"))

        let response2 = try await client.generate(messages: messages, tools: [])

        #expect(response2.content.contains("42"))
    }
}

@Suite(.enabled(if: hasAPIKey, "Requires OPENROUTER_API_KEY environment variable"))
struct AgentIntegrationTests {
    @Test
    func agentCompletesWithFinishTool() async throws {
        let client = OpenAIClient(
            apiKey: apiKey,
            model: defaultModel,
            maxTokens: 1024,
            baseURL: OpenAIClient.openRouterBaseURL
        )

        let agent = Agent<EmptyContext>(client: client, tools: [])
        let result = try await agent.run(
            userMessage: "Say hello and finish. Use the finish tool with content 'Hello!'",
            context: EmptyContext()
        )

        #expect(result.content.lowercased().contains("hello"))
        #expect(result.iterations >= 1)
    }

    @Test
    func agentExecutesTool() async throws {
        let client = OpenAIClient(
            apiKey: apiKey,
            model: defaultModel,
            maxTokens: 1024,
            baseURL: OpenAIClient.openRouterBaseURL
        )

        let addTool = Tool<AddParams, AddOutput, EmptyContext>(
            name: "add",
            description: "Add two numbers together. Always use this tool for addition.",
            executor: { params, _ in AddOutput(sum: params.lhs + params.rhs) }
        )

        let config = AgentConfiguration(
            maxIterations: 5,
            systemPrompt: """
            You are a calculator assistant. When asked to add numbers, use the add tool.
            After getting the result, use the finish tool with the answer.
            """
        )

        let agent = Agent<EmptyContext>(client: client, tools: [addTool], configuration: config)
        let result = try await agent.run(
            userMessage: "What is 17 + 25?",
            context: EmptyContext()
        )

        #expect(result.content.contains("42"))
        #expect(result.iterations >= 1)
    }

    @Test
    func agentHandlesMultipleToolCalls() async throws {
        let client = OpenAIClient(
            apiKey: apiKey,
            model: defaultModel,
            maxTokens: 1024,
            baseURL: OpenAIClient.openRouterBaseURL
        )

        let addTool = Tool<AddParams, AddOutput, EmptyContext>(
            name: "add",
            description: "Add two numbers together",
            executor: { params, _ in AddOutput(sum: params.lhs + params.rhs) }
        )

        let config = AgentConfiguration(
            maxIterations: 10,
            systemPrompt: """
            You are a calculator. Use the add tool for each addition.
            After computing all results, use finish with the final answer.
            """
        )

        let agent = Agent<EmptyContext>(client: client, tools: [addTool], configuration: config)
        let result = try await agent.run(
            userMessage: "Calculate (10 + 5) + 3. Do each addition separately.",
            context: EmptyContext()
        )

        #expect(result.iterations >= 2)
        #expect(result.content.contains("18"))
    }
}

private struct AddParams: Codable, SchemaProviding, Sendable {
    let lhs: Int
    let rhs: Int

    static var jsonSchema: JSONSchema {
        .object(
            properties: [
                "lhs": .integer(description: "First number (left-hand side)"),
                "rhs": .integer(description: "Second number (right-hand side)")
            ],
            required: ["lhs", "rhs"]
        )
    }
}

private struct AddOutput: Codable, Sendable {
    let sum: Int
}

private struct AutoSchemaParams: Codable, SchemaProviding, Sendable {
    let text: String
    let count: Int
    let enabled: Bool
}

private struct EchoOutput: Codable, Sendable {
    let echoed: String
}

@Suite(.enabled(if: hasAPIKey, "Requires OPENROUTER_API_KEY environment variable"))
struct AutoSchemaIntegrationTests {
    @Test
    func autoSchemaToolWithRealLLM() async throws {
        let client = OpenAIClient(
            apiKey: apiKey,
            model: defaultModel,
            maxTokens: 1024,
            baseURL: OpenAIClient.openRouterBaseURL
        )

        let echoTool = Tool<AutoSchemaParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echo the provided text the specified number of times if enabled",
            executor: { params, _ in
                let result = params.enabled ? String(repeating: params.text, count: params.count) : ""
                return EchoOutput(echoed: result)
            }
        )

        let config = AgentConfiguration(
            maxIterations: 5,
            systemPrompt: """
            You are an echo assistant. Use the echo tool when asked to repeat text.
            The tool takes text, count (how many times), and enabled (whether to actually echo).
            After getting result, finish with the echoed text.
            """
        )

        let agent = Agent<EmptyContext>(client: client, tools: [echoTool], configuration: config)
        let result = try await agent.run(
            userMessage: "Echo 'hi' 3 times with enabled=true",
            context: EmptyContext()
        )

        #expect(result.content.contains("hihihi") || result.content.contains("hi hi hi"))
    }

    @Test
    func autoSchemaGeneratesCorrectJSON() throws {
        let schema = AutoSchemaParams.jsonSchema
        guard case let .object(properties, required, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        #expect(properties["text"] == .string())
        #expect(properties["count"] == .integer())
        #expect(properties["enabled"] == .boolean())
        #expect(Set(required) == Set(["text", "count", "enabled"]))
    }
}

private struct SlowParams: Codable, SchemaProviding, Sendable {
    let id: Int
}

private struct SlowOutput: Codable, Sendable {
    let id: Int
    let timestamp: Double
}

private actor ExecutionTimeTracker {
    var times: [Int: Double] = [:]

    func record(id: Int, time: Double) {
        times[id] = time
    }

    func getTimes() -> [Int: Double] {
        times
    }
}

@Suite(.enabled(if: hasAPIKey, "Requires OPENROUTER_API_KEY environment variable"))
struct ParallelExecutionIntegrationTests {
    @Test
    func parallelToolsExecuteConcurrently() async throws {
        let client = OpenAIClient(
            apiKey: apiKey,
            model: defaultModel,
            maxTokens: 1024,
            baseURL: OpenAIClient.openRouterBaseURL
        )

        let tracker = ExecutionTimeTracker()

        let slowTool = Tool<SlowParams, SlowOutput, EmptyContext>(
            name: "slow_task",
            description: "Perform a slow task with given id. Call multiple times with different ids.",
            executor: { params, _ in
                let start = Date().timeIntervalSince1970
                try? await Task.sleep(for: .milliseconds(100))
                let end = Date().timeIntervalSince1970
                await tracker.record(id: params.id, time: start)
                return SlowOutput(id: params.id, timestamp: end)
            }
        )

        let config = AgentConfiguration(
            maxIterations: 5,
            systemPrompt: """
            You run slow tasks. When asked to run multiple tasks, call slow_task multiple times
            with different ids in THE SAME response (parallel calls).
            After all complete, finish with a summary.
            """
        )

        let agent = Agent<EmptyContext>(client: client, tools: [slowTool], configuration: config)

        _ = try await agent.run(
            userMessage: "Run slow_task with id=1 and id=2 and id=3 simultaneously",
            context: EmptyContext()
        )

        let executionTimes = await tracker.getTimes()

        // If parallel, 3 x 100ms tasks should take ~100-200ms not 300ms+
        // Allow generous margin for LLM response time
        #expect(executionTimes.count >= 2, "Expected at least 2 tool executions")

        if executionTimes.count >= 2 {
            let times = executionTimes.values.sorted()
            let timeDiff = times.last! - times.first!
            // If truly parallel, start times should be within 150ms of each other
            #expect(timeDiff < 0.15, "Tools should start within 150ms of each other if parallel")
        }
    }
}
