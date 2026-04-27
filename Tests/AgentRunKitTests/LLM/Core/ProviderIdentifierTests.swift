@testable import AgentRunKit
import Foundation
import Testing

struct ProviderIdentifierTests {
    @Test
    func productionClientsExposeConcreteProviderIdentifiers() throws {
        let openAI = OpenAIClient.openAI(apiKey: "test-key", model: "test-model")
        let anthropic = try AnthropicClient(apiKey: "test-key", model: "claude-sonnet-4-6")
        let gemini = GeminiClient(apiKey: "test-key", model: "gemini-test")
        let responses = ResponsesAPIClient(
            apiKey: "test-key",
            model: "gpt-test",
            baseURL: ResponsesAPIClient.openAIBaseURL,
            store: false
        )
        let vertexAnthropic = try VertexAnthropicClient(
            projectID: "project",
            location: "global",
            model: "claude-sonnet-4-6",
            tokenProvider: { "token" }
        )
        let vertexGoogle = VertexGoogleClient(
            projectID: "project",
            location: "global",
            model: "gemini-test",
            tokenProvider: { "token" }
        )
        let proxyURL = try #require(URL(string: "https://proxy.example.test/v1"))

        #expect(openAI.providerIdentifier == .openAI)
        #expect(OpenAIClient.openRouter(apiKey: "key").providerIdentifier == .openRouter)
        #expect(OpenAIClient.proxy(baseURL: proxyURL).providerIdentifier == .openAICompatible)
        #expect(anthropic.providerIdentifier == .anthropic)
        #expect(gemini.providerIdentifier == .gemini)
        #expect(responses.providerIdentifier == .openAIResponses)
        #expect(vertexAnthropic.providerIdentifier == .vertexAnthropic)
        #expect(vertexGoogle.providerIdentifier == .vertexGoogle)
    }
}
