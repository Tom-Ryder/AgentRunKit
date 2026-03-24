#if canImport(FoundationModels)

    import AgentRunKit
    import Foundation

    @available(macOS 26, iOS 26, *)
    enum FMMessageMapper {
        struct MappedInput: Sendable {
            let instructions: String?
            let prompt: String
        }

        static func map(_ messages: [ChatMessage]) -> MappedInput {
            var systemParts: [String] = []
            var lastUserPrompt: String?

            for message in messages {
                switch message {
                case let .system(content):
                    systemParts.append(content)
                case let .user(content):
                    lastUserPrompt = content
                case let .userMultimodal(parts):
                    let textContent = parts.compactMap { part -> String? in
                        if case let .text(text) = part { return text }
                        return nil
                    }
                    if !textContent.isEmpty {
                        lastUserPrompt = textContent.joined(separator: "\n")
                    }
                case .assistant, .tool:
                    break
                }
            }

            return MappedInput(
                instructions: systemParts.isEmpty ? nil : systemParts.joined(separator: "\n"),
                prompt: lastUserPrompt ?? ""
            )
        }
    }

#endif
