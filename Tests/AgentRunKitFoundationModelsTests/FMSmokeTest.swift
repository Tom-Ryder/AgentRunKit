#if canImport(FoundationModels)

    import AgentRunKit
    import AgentRunKitFoundationModels
    import Foundation
    import FoundationModels
    import Testing

    private let runsFoundationModelsSmoke = ProcessInfo.processInfo.environment["SMOKE_FOUNDATION_MODELS"] == "1"

    private actor ToolCallRecorder {
        private var count = 0

        func record() {
            count += 1
        }

        func recordedCount() -> Int {
            count
        }
    }

    private struct LookupTokenParams: Codable, SchemaProviding {}

    private struct LookupTokenTool: AnyTool {
        typealias Context = EmptyContext
        static let token = "TOOL_TOKEN_314159"

        let recorder: ToolCallRecorder
        let name = "lookup_token"
        let description = "Return the verification token requested by the prompt."
        let parametersSchema = LookupTokenParams.jsonSchema

        func execute(arguments _: Data, context _: EmptyContext) async throws -> ToolResult {
            await recorder.record()
            return .success(Self.token)
        }
    }

    @Suite(
        .enabled(if: runsFoundationModelsSmoke, "Requires SMOKE_FOUNDATION_MODELS=1"),
        .serialized
    ) struct FMSmokeTest {
        @Test func agentRunNoTools() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            guard SystemLanguageModel.default.isAvailable else {
                print("SKIP: On-device model not available")
                return
            }

            let agent = Agent.onDevice(
                tools: [],
                context: EmptyContext(),
                instructions: "Answer in one short sentence."
            )

            let result = try await agent.run(
                userMessage: "What color is the sky?",
                context: EmptyContext()
            )

            print("=== Agent.run() result ===")
            print("Content: \(result.content ?? "(nil)")")
            print("Iterations: \(result.iterations)")
            print("Finish reason: \(result.finishReason)")
            let content = try #require(result.content)
            #expect(!content.isEmpty)
        }

        @Test func agentStreamNoTools() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            guard SystemLanguageModel.default.isAvailable else {
                print("SKIP: On-device model not available")
                return
            }

            let agent = Agent.onDevice(
                tools: [],
                context: EmptyContext(),
                instructions: "Answer in one short sentence."
            )

            print("=== Agent.stream() ===")
            var finalContent: String?
            for try await event in agent.stream(
                userMessage: "Say hello in one word.",
                context: EmptyContext()
            ) {
                switch event.kind {
                case let .delta(text):
                    print("[DELTA] \(text)", terminator: "")
                case let .finished(_, content, _, _):
                    finalContent = content
                    print("\n[FINISHED] content: \(content ?? "(nil)")")
                default:
                    break
                }
            }
            print()
            #expect(finalContent?.isEmpty == false)
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

        @Test func agentRunWithToolBridge() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            guard SystemLanguageModel.default.isAvailable else {
                print("SKIP: On-device model not available")
                return
            }

            let recorder = ToolCallRecorder()
            let tool = LookupTokenTool(recorder: recorder)
            let agent = Agent.onDevice(
                tools: [tool],
                context: EmptyContext(),
                instructions: "Use available tools when a prompt asks for a verification token."
            )

            let result = try await agent.run(
                userMessage: "Use lookup_token and reply with only the exact token it returns.",
                context: EmptyContext()
            )

            print("=== Agent.run() tool bridge ===")
            print("Content: \(result.content ?? "(nil)")")
            let recordedCount = await recorder.recordedCount()
            print("Tool calls: \(recordedCount)")
            #expect(recordedCount > 0)
            let content = try #require(result.content)
            #expect(content.contains(LookupTokenTool.token))
        }

        @Test func chatStreamWithToolBridge() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            guard SystemLanguageModel.default.isAvailable else {
                print("SKIP: On-device model not available")
                return
            }

            let recorder = ToolCallRecorder()
            let tool = LookupTokenTool(recorder: recorder)
            let client = FoundationModelsClient(
                tools: [tool],
                context: EmptyContext(),
                instructions: "Use available tools when a prompt asks for a verification token."
            )
            let chat = Chat<EmptyContext>(client: client, tools: [tool])

            print("=== Chat.stream() tool bridge ===")
            var accumulatedDelta = ""
            var terminalReason: FinishReason?
            var sawTerminalEvent = false
            for try await event in chat.stream(
                "Use lookup_token and reply with only the exact token it returns.",
                context: EmptyContext()
            ) {
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
            let recordedCount = await recorder.recordedCount()
            #expect(recordedCount > 0)
            #expect(!accumulatedDelta.isEmpty)
            #expect(accumulatedDelta.contains(LookupTokenTool.token))
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
