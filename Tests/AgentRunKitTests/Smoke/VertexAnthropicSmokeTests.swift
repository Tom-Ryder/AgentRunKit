@testable import AgentRunKit
import Foundation
import Testing

private let vertexProjectID = ProcessInfo.processInfo.environment["VERTEX_PROJECT_ID"] ?? ""
private let vertexLocation = ProcessInfo.processInfo.environment["VERTEX_LOCATION"] ?? ""
private let anthropicModel = ProcessInfo.processInfo.environment["SMOKE_VERTEX_ANTHROPIC_MODEL"] ?? ""
private let vertexStaticToken = ProcessInfo.processInfo.environment["SMOKE_VERTEX_STATIC_TOKEN"] ?? ""

#if os(macOS)
    private let hasVertexAnthropicADCConfig =
        !vertexProjectID.isEmpty
            && !vertexLocation.isEmpty
            && !anthropicModel.isEmpty
            && GoogleAuthService.credentialsAvailable()

    @Suite(.enabled(
        if: hasVertexAnthropicADCConfig,
        "Requires VERTEX_PROJECT_ID, VERTEX_LOCATION, SMOKE_VERTEX_ANTHROPIC_MODEL, and Google ADC credentials"
    ), .tags(.smoke, .provider, .requiresNetwork))
    struct VertexAnthropicSmokeTests {
        private func makeClient() throws -> VertexAnthropicClient {
            try VertexAnthropicClient(
                projectID: vertexProjectID,
                location: vertexLocation,
                model: anthropicModel,
                authService: GoogleAuthService(),
                maxTokens: 1024
            )
        }

        private func makeBudgetClient() throws -> VertexAnthropicClient {
            try VertexAnthropicClient(
                projectID: vertexProjectID,
                location: vertexLocation,
                model: anthropicModel,
                authService: GoogleAuthService(),
                maxTokens: 1024,
                contextWindowSize: 100
            )
        }

        private func run<Client: LLMClient>(
            test testName: String = #function,
            using client: Client,
            _ body: (Client) async throws -> Void
        ) async throws {
            try await runSmoke(
                target: "vertex_anthropic",
                test: testName,
                provider: "vertex",
                model: anthropicModel,
                using: client,
                body
            )
        }

        @Test
        func budgetHistoryIntegrity() async throws {
            try await run(using: makeBudgetClient()) { client in
                try await assertSmokeBudgetHistoryIntegrity(client: client)
            }
        }

        @Test
        func continuityReplay() async throws {
            try await run(using: makeClient()) { client in
                try await assertSmokeAnthropicContinuityReplay(client: client)
            }
        }
    }
#endif

private let hasVertexAnthropicTokenConfig =
    !vertexProjectID.isEmpty
        && !vertexLocation.isEmpty
        && !anthropicModel.isEmpty
        && !vertexStaticToken.isEmpty

@Suite(.enabled(
    if: hasVertexAnthropicTokenConfig,
    "Requires VERTEX_PROJECT_ID, VERTEX_LOCATION, SMOKE_VERTEX_ANTHROPIC_MODEL, and SMOKE_VERTEX_STATIC_TOKEN"
), .tags(.smoke, .provider, .requiresNetwork))
struct VertexAnthropicTokenProviderSmokeTests {
    private func makeClient() throws -> VertexAnthropicClient {
        try VertexAnthropicClient(
            projectID: vertexProjectID,
            location: vertexLocation,
            model: anthropicModel,
            tokenProvider: { vertexStaticToken },
            maxTokens: 1024,
            contextWindowSize: 100
        )
    }

    private func run<Client: LLMClient>(
        test testName: String = #function,
        using client: Client,
        _ body: (Client) async throws -> Void
    ) async throws {
        try await runSmoke(
            target: "vertex_anthropic_token_provider",
            test: testName,
            provider: "vertex",
            model: anthropicModel,
            using: client,
            body
        )
    }

    @Test
    func budgetHistoryIntegrity() async throws {
        try await run(using: makeClient()) { client in
            try await assertSmokeBudgetHistoryIntegrity(client: client)
        }
    }
}
