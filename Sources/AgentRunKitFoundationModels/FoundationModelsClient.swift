#if canImport(FoundationModels)

    import AgentRunKit
    import Foundation
    import FoundationModels

    /// An LLM client that runs on Apple's on-device foundation model.
    @available(macOS 26, iOS 26, *)
    public struct FoundationModelsClient<C: ToolContext>: LLMClient, Sendable {
        public let contextWindowSize: Int? = 4096

        private let tools: [any AnyTool<C>]
        private let context: C
        private let baseInstructions: String?

        public init(
            tools: [any AnyTool<C>] = [],
            context: C,
            instructions: String? = nil
        ) {
            self.tools = tools
            self.context = context
            baseInstructions = instructions
        }

        public func generate(
            messages: [ChatMessage],
            tools _: [ToolDefinition],
            responseFormat: ResponseFormat?,
            requestContext _: RequestContext?
        ) async throws -> AssistantMessage {
            try messages.validateForLLMRequest()
            if responseFormat != nil {
                throw AgentError.llmError(
                    .other("FoundationModelsClient does not support responseFormat")
                )
            }

            let mapped = FMMessageMapper.map(messages)
            let adapters: [any FoundationModels.Tool] = try tools.map {
                try FMToolAdapter(wrapping: $0, context: context)
            }
            let session = makeSession(adapters: adapters, mapped: mapped)
            let response = try await session.respond(to: mapped.prompt)
            return Self.synthesizeFinish(content: response.content)
        }

        public func stream(
            messages: [ChatMessage],
            tools _: [ToolDefinition],
            requestContext _: RequestContext?
        ) -> AsyncThrowingStream<StreamDelta, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        try messages.validateForLLMRequest()
                        let mapped = FMMessageMapper.map(messages)
                        let adapters: [any FoundationModels.Tool] = try tools.map {
                            try FMToolAdapter(wrapping: $0, context: context)
                        }
                        let session = makeSession(adapters: adapters, mapped: mapped)

                        let stream = session.streamResponse(to: mapped.prompt)
                        var previousUTF8Count = 0

                        for try await snapshot in stream {
                            let current = snapshot.content
                            let currentUTF8Count = current.utf8.count
                            if currentUTF8Count > previousUTF8Count {
                                let startIndex = current.utf8.index(
                                    current.utf8.startIndex,
                                    offsetBy: previousUTF8Count
                                )
                                let delta = String(current.utf8[startIndex...])
                                if let delta {
                                    continuation.yield(.content(delta))
                                }
                            }
                            previousUTF8Count = currentUTF8Count
                        }

                        continuation.yield(.finished(usage: nil))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: mapError(error))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        private func makeSession(
            adapters: [any FoundationModels.Tool],
            mapped: FMMessageMapper.MappedInput
        ) -> LanguageModelSession {
            let instructions = mergeInstructions(mapped.instructions)
            if let instructions {
                return LanguageModelSession(tools: adapters) { instructions }
            }
            return LanguageModelSession(tools: adapters)
        }

        func mergeInstructions(_ messageInstructions: String?) -> String? {
            switch (baseInstructions, messageInstructions) {
            case let (.some(base), .some(fromMessages)):
                base + "\n" + fromMessages
            case let (.some(base), .none):
                base
            case let (.none, .some(fromMessages)):
                fromMessages
            case (.none, .none):
                nil
            }
        }

        static func synthesizeFinish(content: String) -> AssistantMessage {
            let finishArgs = FinishArguments(content: content)
            guard let data = try? JSONEncoder().encode(finishArgs),
                  let arguments = String(data: data, encoding: .utf8)
            else {
                preconditionFailure("FinishArguments encoding failed")
            }
            let finishCall = ToolCall(
                id: "fm_finish", name: "finish", arguments: arguments
            )
            return AssistantMessage(content: "", toolCalls: [finishCall])
        }

        private func mapError(_ error: Error) -> Error {
            if let agentError = error as? AgentError {
                return agentError
            }
            return AgentError.llmError(.other(String(describing: error)))
        }
    }

#endif
