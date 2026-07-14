#if canImport(FoundationModels)

    import AgentRunKit
    import AgentRunKitFoundationModels
    import Foundation
    import FoundationModels
    import Testing

    private let runsFoundationModelsSmoke = ProcessInfo.processInfo.environment["SMOKE_FOUNDATION_MODELS"] == "1"

    private let onDeviceModelIsAvailable: Bool = {
        guard #available(macOS 26, iOS 26, *) else { return false }
        return SystemLanguageModel.default.isAvailable
    }()

    private actor ToolCallRecorder {
        private var count = 0

        func record() {
            count += 1
        }

        func recordedCount() -> Int {
            count
        }
    }

    private struct ShipmentOrigin: Codable, Equatable {
        let city: String
    }

    private struct ShipmentDestination: Codable, Equatable {
        let code: Int
    }

    private struct RegisterShipmentParams: Codable, SchemaProviding, Equatable {
        let origin: ShipmentOrigin
        let destination: ShipmentDestination
    }

    private struct RegisteredShipment: Codable {
        let status: String
    }

    private func makeShipmentTool(
        recorder: ParamsRecorder<RegisterShipmentParams>
    ) throws -> AgentRunKit.Tool<RegisterShipmentParams, RegisteredShipment, EmptyContext> {
        try AgentRunKit.Tool(
            name: "register_shipment",
            description: "Registers a shipment from an origin city to a numeric destination code."
        ) { params, _ in
            await recorder.record(params)
            return RegisteredShipment(status: "registered")
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
        @available(macOS 26, iOS 26, *)
        @Test(.enabled(if: onDeviceModelIsAvailable, "Requires an available on-device model"))
        func agentRunNoTools() async throws {
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

        @available(macOS 26, iOS 26, *)
        @Test(.enabled(if: onDeviceModelIsAvailable, "Requires an available on-device model"))
        func agentStreamNoTools() async throws {
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

        @available(macOS 26, iOS 26, *)
        @Test(.enabled(if: onDeviceModelIsAvailable, "Requires an available on-device model"))
        func clientGenerateNoTools() async throws {
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

        @available(macOS 26, iOS 26, *)
        @Test(.enabled(if: onDeviceModelIsAvailable, "Requires an available on-device model"))
        func agentRunWithToolBridge() async throws {
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

        @available(macOS 26, iOS 26, *)
        @Test(.enabled(if: onDeviceModelIsAvailable, "Requires an available on-device model"))
        func nestedObjectArgumentsReachTypedTool() async throws {
            let recorder = ParamsRecorder<RegisterShipmentParams>()
            let tool = try makeShipmentTool(recorder: recorder)
            let agent = Agent.onDevice(
                tools: [tool],
                context: EmptyContext(),
                instructions: "Use the register_shipment tool to register shipments exactly as requested."
            )

            let result = try await agent.run(
                userMessage: "Register a shipment from origin city \"Lisbon\" to destination code 4271. "
                    + "Call register_shipment exactly once with origin.city = \"Lisbon\" "
                    + "and destination.code = 4271.",
                context: EmptyContext()
            )

            print("=== Nested-object tool bridge ===")
            print("Content: \(result.content ?? "(nil)")")
            let received = await recorder.received
            print("Recorded invocations: \(received)")
            try #require(
                !received.isEmpty,
                """
                Model-routing integration failure: register_shipment was never invoked; schema-contract \
                coverage lives in the converter, boundary, and adapter suites.
                """
            )
            let expected = RegisterShipmentParams(
                origin: ShipmentOrigin(city: "Lisbon"),
                destination: ShipmentDestination(code: 4271)
            )
            #expect(received.allSatisfy { $0 == expected })
        }

        @available(macOS 26, iOS 26, *)
        @Test(.enabled(if: onDeviceModelIsAvailable, "Requires an available on-device model"))
        func chatStreamWithToolBridge() async throws {
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

        @available(macOS 26, iOS 26, *)
        @Test(.enabled(if: onDeviceModelIsAvailable, "Requires an available on-device model"))
        func chatSendReturnsPlainContent() async throws {
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
