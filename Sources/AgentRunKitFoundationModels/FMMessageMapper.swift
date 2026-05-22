#if canImport(FoundationModels)

    import AgentRunKit
    import Foundation

    @available(macOS 26, iOS 26, *)
    enum FMMessageMapper {
        struct MappedInput {
            let instructions: String?
            let prompt: String
        }

        static func map(_ messages: [ChatMessage]) throws -> MappedInput {
            var systemParts: [String] = []
            var userPrompt: String?

            for message in messages {
                switch message {
                case let .system(content):
                    guard userPrompt == nil else { throw unsupportedMappingError }
                    systemParts.append(content)
                case let .user(content):
                    try assignPrompt(content, to: &userPrompt)
                case let .userMultimodal(parts):
                    try assignPrompt(textOnlyPrompt(from: parts), to: &userPrompt)
                case .assistant, .tool:
                    throw unsupportedMappingError
                }
            }

            guard let userPrompt else { throw unsupportedMappingError }
            return MappedInput(
                instructions: systemParts.isEmpty ? nil : systemParts.joined(separator: "\n"),
                prompt: userPrompt
            )
        }

        private static func assignPrompt(_ prompt: String, to currentPrompt: inout String?) throws {
            guard currentPrompt == nil, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw unsupportedMappingError
            }
            currentPrompt = prompt
        }

        private static func textOnlyPrompt(from parts: [ContentPart]) throws -> String {
            var textParts: [String] = []
            for part in parts {
                guard case let .text(text) = part else {
                    throw unsupportedMappingError
                }
                textParts.append(text)
            }
            return textParts.joined(separator: "\n")
        }

        private static var unsupportedMappingError: AgentError {
            .llmError(.featureUnsupported(
                provider: ProviderIdentifier.foundationModels.description,
                feature: "single-turn text-only message mapping"
            ))
        }
    }

#endif
