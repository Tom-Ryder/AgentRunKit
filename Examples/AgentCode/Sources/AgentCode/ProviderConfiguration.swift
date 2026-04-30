import AgentRunKit
import Foundation

enum ProviderProfile: String {
    case openai
    case openrouter
    case compatible
}

struct ProviderConfiguration {
    let client: any LLMClient
    let description: String
    let offline: Bool

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        forceOffline: Bool
    ) throws -> Self {
        if forceOffline || environment["OPENAI_API_KEY"] == nil {
            return ProviderConfiguration(
                client: OfflineDemoClient(),
                description: "offline demo client",
                offline: true
            )
        }

        let apiKey = environment["OPENAI_API_KEY"] ?? ""
        let model = environment["OPENAI_MODEL"] ?? "gpt-5.4"
        let profile = resolvedProfile(environment: environment)

        switch profile {
        case .openai:
            return ProviderConfiguration(
                client: OpenAIClient.openAI(apiKey: apiKey, model: model),
                description: "OpenAI Chat Completions (\(model))",
                offline: false
            )
        case .openrouter:
            return ProviderConfiguration(
                client: OpenAIClient.openRouter(apiKey: apiKey, model: model),
                description: "OpenRouter Chat Completions (\(model))",
                offline: false
            )
        case .compatible:
            guard let value = environment["OPENAI_BASE_URL"],
                  let baseURL = URL(string: value),
                  baseURL.scheme != nil,
                  baseURL.host != nil else {
                throw AgentCodeError.invalidBaseURL(environment["OPENAI_BASE_URL"] ?? "")
            }
            return ProviderConfiguration(
                client: OpenAIClient(
                    apiKey: apiKey,
                    model: model,
                    baseURL: baseURL,
                    profile: .compatible
                ),
                description: "OpenAI-compatible Chat Completions (\(model), \(baseURL.absoluteString))",
                offline: false
            )
        }
    }

    private static func resolvedProfile(environment: [String: String]) -> ProviderProfile {
        if let rawValue = environment["OPENAI_PROFILE"],
           let profile = ProviderProfile(rawValue: rawValue.lowercased()) {
            return profile
        }
        if environment["OPENAI_BASE_URL"]?.contains("openrouter.ai") == true {
            return .openrouter
        }
        if environment["OPENAI_BASE_URL"] != nil {
            return .compatible
        }
        return .openai
    }
}

struct OfflineDemoClient: LLMClient {
    let providerIdentifier: ProviderIdentifier = .custom("offline-demo")

    func generate(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        AssistantMessage(content: Self.message)
    }

    func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.content(Self.message))
            continuation.yield(.finished(usage: nil))
            continuation.finish()
        }
    }

    private static let message = "Offline mode is active. Set OPENAI_API_KEY to run the interactive coding agent."
}
