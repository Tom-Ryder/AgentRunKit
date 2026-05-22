#if canImport(FoundationModels)

    import AgentRunKit
    @testable import AgentRunKitFoundationModels
    import Foundation
    import Testing

    @Suite(.serialized) struct FoundationModelsClientTests {
        @Test func contextWindowSize() {
            guard #available(macOS 26, iOS 26, *) else { return }
            let client = FoundationModelsClient<EmptyContext>(context: EmptyContext())
            #expect(client.contextWindowSize == nil)
        }

        @Test func contextBudgetConfigurationThrowsBecauseWindowSizeIsNil() async {
            guard #available(macOS 26, iOS 26, *) else { return }
            let client = FoundationModelsClient<EmptyContext>(context: EmptyContext())
            let agent = Agent<EmptyContext>(
                client: client,
                tools: [],
                configuration: AgentConfiguration(
                    contextBudget: ContextBudgetConfig(enableVisibility: true)
                )
            )

            await #expect(throws: AgentError.contextBudgetWindowSizeUnavailable) {
                _ = try await agent.run(userMessage: "go", context: EmptyContext())
            }
            await #expect(throws: AgentError.contextBudgetWindowSizeUnavailable) {
                for try await _ in agent.stream(userMessage: "go", context: EmptyContext()) {}
            }
        }

        @Test func responseFormatThrows() async {
            guard #available(macOS 26, iOS 26, *) else { return }
            let client = FoundationModelsClient<EmptyContext>(context: EmptyContext())
            await #expect(throws: AgentError.self) {
                try await client.generate(
                    messages: [.user("test")],
                    tools: [],
                    responseFormat: ResponseFormat.jsonSchema(DummySchema.self),
                    requestContext: nil
                )
            }
        }

        @Test func mergeInstructionsBothPresent() {
            guard #available(macOS 26, iOS 26, *) else { return }
            let client = FoundationModelsClient<EmptyContext>(
                context: EmptyContext(), instructions: "Base"
            )
            let result = client.mergeInstructions("FromMessages")
            #expect(result == "Base\nFromMessages")
        }

        @Test func mergeInstructionsBaseOnly() {
            guard #available(macOS 26, iOS 26, *) else { return }
            let client = FoundationModelsClient<EmptyContext>(
                context: EmptyContext(), instructions: "Base"
            )
            #expect(client.mergeInstructions(nil) == "Base")
        }

        @Test func mergeInstructionsMessageOnly() {
            guard #available(macOS 26, iOS 26, *) else { return }
            let client = FoundationModelsClient<EmptyContext>(context: EmptyContext())
            #expect(client.mergeInstructions("FromMessages") == "FromMessages")
        }

        @Test func mergeInstructionsBothNil() {
            guard #available(macOS 26, iOS 26, *) else { return }
            let client = FoundationModelsClient<EmptyContext>(context: EmptyContext())
            #expect(client.mergeInstructions(nil) == nil)
        }

        @Test func generateRejectsMalformedHistory() async {
            guard #available(macOS 26, iOS 26, *) else { return }
            let client = FoundationModelsClient<EmptyContext>(context: EmptyContext())
            let malformedHistory: [ChatMessage] = [
                .user("Hi"),
                .assistant(AssistantMessage(
                    content: "",
                    toolCalls: [ToolCall(id: "call_1", name: "lookup", arguments: "{}")]
                )),
            ]

            await #expect(throws: AgentError.malformedHistory(.unfinishedToolCallBatch(ids: ["call_1"]))) {
                _ = try await client.generate(
                    messages: malformedHistory,
                    tools: [],
                    responseFormat: nil,
                    requestContext: nil
                )
            }
        }

        @Test func streamRejectsMalformedHistory() async {
            guard #available(macOS 26, iOS 26, *) else { return }
            let client = FoundationModelsClient<EmptyContext>(context: EmptyContext())
            let malformedHistory: [ChatMessage] = [
                .user("Hi"),
                .assistant(AssistantMessage(
                    content: "",
                    toolCalls: [ToolCall(id: "call_1", name: "lookup", arguments: "{}")]
                )),
            ]

            await #expect(throws: AgentError.malformedHistory(.unfinishedToolCallBatch(ids: ["call_1"]))) {
                for try await _ in client.stream(messages: malformedHistory, tools: [], requestContext: nil) {}
            }
        }

        @Test func generateRejectsMultiTurnHistory() async {
            guard #available(macOS 26, iOS 26, *) else { return }
            let client = FoundationModelsClient<EmptyContext>(context: EmptyContext())

            await #expect {
                _ = try await client.generate(
                    messages: resolvedToolHistory,
                    tools: [],
                    responseFormat: nil,
                    requestContext: nil
                )
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @Test func streamRejectsMultiTurnHistory() async {
            guard #available(macOS 26, iOS 26, *) else { return }
            let client = FoundationModelsClient<EmptyContext>(context: EmptyContext())

            await #expect {
                for try await _ in client.stream(messages: resolvedToolHistory, tools: [], requestContext: nil) {}
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @Test func generateRejectsSystemAfterUser() async {
            guard #available(macOS 26, iOS 26, *) else { return }
            let client = FoundationModelsClient<EmptyContext>(context: EmptyContext())

            await #expect {
                _ = try await client.generate(
                    messages: trailingSystemHistory,
                    tools: [],
                    responseFormat: nil,
                    requestContext: nil
                )
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @Test func streamRejectsSystemAfterUser() async {
            guard #available(macOS 26, iOS 26, *) else { return }
            let client = FoundationModelsClient<EmptyContext>(context: EmptyContext())

            await #expect {
                for try await _ in client.stream(messages: trailingSystemHistory, tools: [], requestContext: nil) {}
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }
    }

    private struct DummySchema: SchemaProviding, Codable {
        static let jsonSchema = JSONSchema.object(properties: [:], required: [])
    }

    private let resolvedToolHistory: [ChatMessage] = [
        .user("Hi"),
        .assistant(AssistantMessage(
            content: "",
            toolCalls: [ToolCall(id: "call_1", name: "lookup", arguments: "{}")]
        )),
        .tool(id: "call_1", name: "lookup", content: "result"),
        .user("Continue"),
    ]

    private let trailingSystemHistory: [ChatMessage] = [
        .user("Hi"),
        .system("Late instruction"),
    ]

#endif
