@testable import AgentRunKit
import Foundation
import Testing

struct OpenAIChatStreamingReasoningTests {
    private func makeClient(baseURL: URL, session: URLSession) -> OpenAIClient {
        OpenAIClient(
            apiKey: "test-key",
            model: "anthropic/claude-opus-4.8",
            baseURL: baseURL,
            session: session,
            assistantReplayProfile: .openRouterReasoningDetails
        )
    }

    private func sseLine(_ json: String) -> String {
        "data: \(json)"
    }

    private func reasoningEvent(_ detail: String) -> String {
        sseLine(#"{"choices":[{"index":0,"delta":{"reasoning_details":[\#(detail)]}}]}"#)
    }

    private func reasoningDetailsStreamBody() -> Data {
        let hello = #"{"type":"reasoning.text","format":"anthropic-claude-v1","index":0,"text":"Hello"}"#
        let world = #"{"type":"reasoning.text","format":"anthropic-claude-v1","index":0,"text":" world"}"#
        let signature = #"{"type":"reasoning.text","format":"anthropic-claude-v1","index":0,"signature":"sig-abc"}"#
        let events = [
            reasoningEvent(hello),
            reasoningEvent(world),
            reasoningEvent(signature),
            sseLine(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#),
        ]
        return Data((events.joined(separator: "\n\n") + "\n\ndata: [DONE]\n\n").utf8)
    }

    @Test
    func streamingReasoningDetailDeltasDecodedFromBytes() async throws {
        let session = URLSession(configuration: StreamingTestURLProtocol.configuration())
        defer { session.invalidateAndCancel() }
        let client = try makeClient(
            baseURL: #require(URL(string: "https://openrouter-reasoning-deltas.test/v1")),
            session: session
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [], stream: true)
        let requestURL = try #require(client.buildURLRequest(request).url)
        StreamingTestURLProtocol.register(url: requestURL, body: reasoningDetailsStreamBody())
        defer { StreamingTestURLProtocol.unregister(url: requestURL) }

        let (deltas, error) = await collectStreamResult(
            client.stream(messages: [.user("Hi")], tools: [], requestContext: nil)
        )
        #expect(error == nil)

        let reasoningDeltas = deltas.compactMap { delta -> [JSONValue]? in
            guard case let .reasoningDetails(details) = delta else { return nil }
            return details
        }
        #expect(reasoningDeltas.count == 3)
        #expect(reasoningDeltas.first == [.object([
            "type": .string("reasoning.text"),
            "format": .string("anthropic-claude-v1"),
            "index": .int(0),
            "text": .string("Hello"),
        ])])
        #expect(reasoningDeltas.last == [.object([
            "type": .string("reasoning.text"),
            "format": .string("anthropic-claude-v1"),
            "index": .int(0),
            "signature": .string("sig-abc"),
        ])])
    }

    @Test
    func streamingReasoningDetailsConsolidateIntoSingleBlock() async throws {
        let session = URLSession(configuration: StreamingTestURLProtocol.configuration())
        defer { session.invalidateAndCancel() }
        let client = try makeClient(
            baseURL: #require(URL(string: "https://openrouter-reasoning-merge.test/v1")),
            session: session
        )
        let request = try client.buildRequest(messages: [.user("Hi")], tools: [], stream: true)
        let requestURL = try #require(client.buildURLRequest(request).url)
        StreamingTestURLProtocol.register(url: requestURL, body: reasoningDetailsStreamBody())
        defer { StreamingTestURLProtocol.unregister(url: requestURL) }

        let processor = StreamProcessor(
            client: client,
            toolDefinitions: [],
            policy: .chat,
            eventFactory: StreamEventFactory(sessionID: nil, runID: nil, origin: .live)
        )
        let (_, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        var totalUsage = TokenUsage()
        var emittedOutput = false
        let iteration = try await processor.process(
            messages: [.user("Hi")],
            totalUsage: &totalUsage,
            emittedOutput: &emittedOutput,
            continuation: continuation
        )

        let details = try #require(iteration.toAssistantMessage().reasoningDetails)
        #expect(details.count == 1)
        #expect(details[0] == .object([
            "type": .string("reasoning.text"),
            "format": .string("anthropic-claude-v1"),
            "index": .int(0),
            "text": .string("Hello world"),
            "signature": .string("sig-abc"),
        ]))
    }
}
