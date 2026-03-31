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

    @Suite(.disabled("Requires Apple Intelligence on-device"))
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
            print("Response toolCalls: \(response.toolCalls)")
            #expect(response.toolCalls.count == 1)
            #expect(response.toolCalls[0].name == "finish")

            let finishData = Data(response.toolCalls[0].arguments.utf8)
            let finish = try JSONDecoder().decode(FinishArguments.self, from: finishData)
            print("Finish content: \(finish.content)")
            #expect(!finish.content.isEmpty)
        }
    }

#endif
