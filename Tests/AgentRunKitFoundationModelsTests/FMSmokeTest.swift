#if canImport(FoundationModels)

    import AgentRunKit
    import AgentRunKitFoundationModels
    import Foundation
    import FoundationModels
    import Testing

    private struct CalculatorParams: Codable, SchemaProviding {
        let expression: String
    }

    private struct CalculatorTool: AnyTool {
        typealias Context = EmptyContext
        let name = "calculate"
        let description = "Evaluate a simple math expression and return the numeric result"
        let parametersSchema = CalculatorParams.jsonSchema

        func execute(arguments: Data, context _: EmptyContext) async throws -> ToolResult {
            let params = try JSONDecoder().decode(CalculatorParams.self, from: arguments)
            let sanitized = params.expression.filter { "0123456789.+-*/() ".contains($0) }
            guard !sanitized.isEmpty else {
                return .error("Invalid expression: \(params.expression)")
            }
            let expr = NSExpression(format: sanitized)
            guard let value = (expr.expressionValue(with: nil, context: nil) as? NSNumber)?.doubleValue else {
                return .error("Cannot evaluate: \(params.expression)")
            }
            return .success(String(value))
        }
    }

    struct FMSmokeTest {
        @Test func agentRunWithCalculator() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            guard SystemLanguageModel.default.isAvailable else {
                print("SKIP: On-device model not available")
                return
            }

            let agent = Agent.onDevice(
                tools: [CalculatorTool()],
                context: EmptyContext(),
                instructions: "You are a calculator assistant. Use the calculate tool to answer math questions."
            )

            let result = try await agent.run(
                userMessage: "What is 42 * 17?",
                context: EmptyContext()
            )

            print("=== Agent.run() result ===")
            print("Content: \(result.content ?? "(nil)")")
            print("Iterations: \(result.iterations)")
            print("Finish reason: \(result.finishReason)")
            let content = try #require(result.content)
            #expect(content.contains("714"))
        }

        @Test func agentStreamWithCalculator() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            guard SystemLanguageModel.default.isAvailable else {
                print("SKIP: On-device model not available")
                return
            }

            let agent = Agent.onDevice(
                tools: [CalculatorTool()],
                context: EmptyContext(),
                instructions: "You are a calculator assistant. Use the calculate tool to answer math questions."
            )

            print("=== Agent.stream() ===")
            var finalContent: String?
            for try await event in agent.stream(
                userMessage: "What is 99 + 1?",
                context: EmptyContext()
            ) {
                switch event.kind {
                case let .delta(text):
                    print("[DELTA] \(text)", terminator: "")
                case let .toolCallStarted(name, _):
                    print("\n[TOOL] \(name)")
                case let .toolCallCompleted(_, name, result):
                    print("[RESULT] \(name): \(result.content)")
                case let .finished(_, content, _, _):
                    finalContent = content
                    print("\n[FINISHED] content: \(content ?? "(nil)")")
                default:
                    break
                }
            }
            print()
            #expect(finalContent?.contains("100") == true)
        }

        @Test func clientGenerateNoTools() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            guard SystemLanguageModel.default.isAvailable else {
                print("SKIP: On-device model not available")
                return
            }

            let client = FoundationModelsClient<EmptyContext>(context: EmptyContext())
            let response = try await client.generate(
                messages: [
                    .system("Answer in one sentence."),
                    .user("What color is the sky?"),
                ],
                tools: []
            )

            print("=== No-tool generate ===")
            print("Response content: \(response.content)")
            #expect(response.toolCalls.isEmpty)
            #expect(!response.content.isEmpty)
        }

        @Test func chatStreamWithCalculator() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            guard SystemLanguageModel.default.isAvailable else {
                print("SKIP: On-device model not available")
                return
            }

            let client = FoundationModelsClient(
                tools: [CalculatorTool()],
                context: EmptyContext(),
                instructions: "You are a calculator assistant. Use the calculate tool to answer math questions."
            )
            let chat = Chat<EmptyContext>(client: client, tools: [CalculatorTool()])

            print("=== Chat.stream() ===")
            var accumulatedDelta = ""
            var terminalReason: FinishReason?
            var sawTerminalEvent = false
            for try await event in chat.stream("What is 2 + 2?", context: EmptyContext()) {
                switch event.kind {
                case let .delta(text) where !text.isEmpty:
                    accumulatedDelta += text
                    print("[DELTA] \(text)", terminator: "")
                case let .finished(_, content, reason, _):
                    sawTerminalEvent = true
                    terminalReason = reason
                    print("\n[FINISHED] content: \(content ?? "(nil)") reason: \(String(describing: reason))")
                default:
                    break
                }
            }
            print()

            #expect(sawTerminalEvent)
            #expect(terminalReason == nil)
            #expect(!accumulatedDelta.isEmpty)
        }

        @Test func chatSendReturnsPlainContent() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            guard SystemLanguageModel.default.isAvailable else {
                print("SKIP: On-device model not available")
                return
            }

            let client = FoundationModelsClient<EmptyContext>(context: EmptyContext())
            let chat = Chat<EmptyContext>(client: client)
            let (response, _) = try await chat.send("Say hello in one word.")

            print("=== Chat.send() ===")
            print("Response content: \(response.content)")
            #expect(!response.content.isEmpty)
            #expect(response.toolCalls.isEmpty)
        }
    }

#endif
