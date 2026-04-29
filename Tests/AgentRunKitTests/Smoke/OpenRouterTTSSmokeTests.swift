@testable import AgentRunKit
import Foundation
import Testing

private let openRouterTTSAPIKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? ""
private let hasOpenRouterTTSAPIKey = !openRouterTTSAPIKey.isEmpty
private let openRouterTTSModel = ProcessInfo.processInfo.environment["SMOKE_OPENROUTER_TTS_MODEL"]
    ?? "google/gemini-3.1-flash-tts-preview"
private let openRouterTTSVoice = ProcessInfo.processInfo.environment["SMOKE_OPENROUTER_TTS_VOICE"] ?? "Kore"

@Suite(
    .enabled(if: hasOpenRouterTTSAPIKey, "Requires OPENROUTER_API_KEY environment variable"),
    .tags(.smoke, .provider, .requiresNetwork)
)
struct OpenRouterTTSSmokeTests {
    private let provider = OpenAITTSProvider(
        apiKey: openRouterTTSAPIKey,
        model: openRouterTTSModel,
        baseURL: OpenAIClient.openRouterBaseURL,
        maxChunkCharacters: 512,
        defaultVoice: openRouterTTSVoice,
        defaultFormat: .pcm,
        retryPolicy: RetryPolicy(maxAttempts: 1)
    )

    private func run(
        test testName: String = #function,
        _ body: () async throws -> Void
    ) async throws {
        try await runSmoke(
            target: "openrouter_tts",
            test: testName,
            provider: "openrouter",
            model: openRouterTTSModel,
            body
        )
    }

    @Test func geminiTTSGenerateWithManifestReturnsPCMByteRanges() async throws {
        try await run {
            let client = TTSClient(provider: provider, maxConcurrent: 1)
            let text = "This is a short AgentRunKit OpenRouter text to speech smoke test."
            let planned = client.chunks(for: text)

            let result = try await client.generateWithManifest(text: text)

            try smokeExpect(result.audio.count > 256)
            try smokeExpect(result.manifest.count == planned.count)
            let entry = try smokeRequire(result.manifest.first)
            let range = try smokeRequire(entry.timing.byteRangeInConcatenatedAudio)
            try smokeExpect(entry.chunk == planned.first)
            try smokeExpect(entry.encoding.format == .pcm)
            try smokeExpect(range == result.audio.startIndex ..< result.audio.endIndex)
            try smokeExpect(result.audio.subdata(in: range) == result.audio)
        }
    }
}
