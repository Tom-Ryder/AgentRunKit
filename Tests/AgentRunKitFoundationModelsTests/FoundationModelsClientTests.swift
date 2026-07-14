#if canImport(FoundationModels)

    import AgentRunKit
    @testable import AgentRunKitFoundationModels
    import Foundation
    import Testing

    @Suite(.serialized) struct FoundationModelsClientTests {
        @available(macOS 26, iOS 26, *)
        @Test func contextWindowSize() {
            let client = FoundationModelsClient<EmptyContext>(context: EmptyContext())
            #expect(client.contextWindowSize == nil)
        }

        @available(macOS 26, iOS 26, *)
        @Test func contextBudgetConfigurationThrowsBecauseWindowSizeIsNil() async {
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

        @available(macOS 26, iOS 26, *)
        @Test func responseFormatThrows() async {
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

        @available(macOS 26, iOS 26, *)
        @Test func mergeInstructionsBothPresent() {
            let client = FoundationModelsClient<EmptyContext>(
                context: EmptyContext(), instructions: "Base"
            )
            let result = client.mergeInstructions("FromMessages")
            #expect(result == "Base\nFromMessages")
        }

        @available(macOS 26, iOS 26, *)
        @Test func mergeInstructionsBaseOnly() {
            let client = FoundationModelsClient<EmptyContext>(
                context: EmptyContext(), instructions: "Base"
            )
            #expect(client.mergeInstructions(nil) == "Base")
        }

        @available(macOS 26, iOS 26, *)
        @Test func mergeInstructionsMessageOnly() {
            let client = FoundationModelsClient<EmptyContext>(context: EmptyContext())
            #expect(client.mergeInstructions("FromMessages") == "FromMessages")
        }

        @available(macOS 26, iOS 26, *)
        @Test func mergeInstructionsBothNil() {
            let client = FoundationModelsClient<EmptyContext>(context: EmptyContext())
            #expect(client.mergeInstructions(nil) == nil)
        }

        @available(macOS 26, iOS 26, *)
        @Test func generateRejectsMalformedHistory() async {
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

        @available(macOS 26, iOS 26, *)
        @Test func streamRejectsMalformedHistory() async {
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

        @available(macOS 26, iOS 26, *)
        @Test func generateRejectsMultiTurnHistory() async {
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

        @available(macOS 26, iOS 26, *)
        @Test func streamRejectsMultiTurnHistory() async {
            let client = FoundationModelsClient<EmptyContext>(context: EmptyContext())

            await #expect {
                for try await _ in client.stream(messages: resolvedToolHistory, tools: [], requestContext: nil) {}
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @available(macOS 26, iOS 26, *)
        @Test func generateRejectsSystemAfterUser() async {
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

        @available(macOS 26, iOS 26, *)
        @Test func streamRejectsSystemAfterUser() async {
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
