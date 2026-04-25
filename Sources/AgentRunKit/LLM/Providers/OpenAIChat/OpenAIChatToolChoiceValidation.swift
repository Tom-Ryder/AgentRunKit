import Foundation

extension OpenAIClient {
    func validateRequiredToolChoice(_ requestTools: [RequestTool]) throws {
        guard !requestTools.isEmpty else {
            throw AgentError.llmError(.other("OpenAI Chat toolChoice.required requires at least one tool"))
        }
    }

    func validateRequestedFunctionChoice(
        _ name: String,
        functions: Set<String>
    ) throws {
        guard functions.contains(name) else {
            throw AgentError.llmError(.other(
                "OpenAI Chat toolChoice.function requires tool '\(name)' in the request"
            ))
        }
    }

    func validateRequestedCustomChoice(
        _ name: String,
        customs: Set<String>,
        capabilities: OpenAIChatCapabilities
    ) throws {
        guard capabilities.supportsCustomTools else {
            throw AgentError.llmError(.featureUnsupported(
                provider: "openai-chat-\(capabilities.profile)",
                feature: "custom tool choice"
            ))
        }
        guard customs.contains(name) else {
            throw AgentError.llmError(.other(
                "OpenAI Chat toolChoice.custom requires custom tool '\(name)' in the request"
            ))
        }
    }

    func validateAllowedTools(
        _ tools: [OpenAIChatAllowedTool],
        functions: Set<String>,
        customs: Set<String>,
        capabilities: OpenAIChatCapabilities
    ) throws {
        guard capabilities.profile == .firstParty else {
            throw AgentError.llmError(.featureUnsupported(
                provider: "openai-chat-\(capabilities.profile)",
                feature: "allowed tools"
            ))
        }
        guard !tools.isEmpty else {
            throw AgentError.llmError(.other("OpenAI Chat allowed tools must not be empty"))
        }
        for tool in tools {
            switch tool {
            case let .function(name):
                guard functions.contains(name) else {
                    throw AgentError.llmError(.other(
                        "OpenAI Chat allowed function tool '\(name)' is missing from the request"
                    ))
                }
            case let .custom(name):
                guard customs.contains(name) else {
                    throw AgentError.llmError(.other(
                        "OpenAI Chat allowed custom tool '\(name)' is missing from the request"
                    ))
                }
            }
        }
    }
}
