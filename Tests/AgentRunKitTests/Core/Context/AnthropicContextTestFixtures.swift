@testable import AgentRunKit
import Foundation
import Testing

enum AnthropicContextExecution: CaseIterable {
    case blocking, streaming
}

let anthropicCachedContextUsage = #"{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":600,"#
    + #""cache_creation_input_tokens":100,"output_tokens_details":{"thinking_tokens":20}}"#

private struct AnthropicContextToolParameters: Codable, SchemaProviding {}

func makeAnthropicContextTool() throws -> some AnyTool<EmptyContext> {
    try Tool<AnthropicContextToolParameters, AnthropicContextToolParameters, EmptyContext>(
        name: "noop", description: "No-op", executor: { parameters, _ in parameters }
    )
}

enum AnthropicContextReply {
    case tool(id: String)
    case finish
    case text(String)

    func response(execution: AnthropicContextExecution, usage: String?) throws -> HTTPTestResponse {
        let block: JSONValue
        let delta: JSONValue
        switch self {
        case let .tool(id):
            block = .object([
                "type": .string("tool_use"), "id": .string(id), "name": .string("noop"), "input": .object([:])
            ])
            delta = .object(["type": .string("input_json_delta"), "partial_json": .string("{}")])
        case .finish:
            block = .object([
                "type": .string("tool_use"), "id": .string("finish_1"), "name": .string("finish"),
                "input": .object(["content": .string("done")])
            ])
            delta = .object([
                "type": .string("input_json_delta"), "partial_json": .string(#"{"content":"done"}"#)
            ])
        case let .text(content):
            block = .object(["type": .string("text"), "text": .string(content)])
            delta = .object(["type": .string("text_delta"), "text": .string(content)])
        }
        let blockJSON = try #require(String(data: JSONEncoder().encode(block), encoding: .utf8))
        let usageField = usage.map { #", "usage":\#($0)"# } ?? ""
        switch execution {
        case .blocking:
            return HTTPTestResponse(body: Data(#"{"content":[\#(blockJSON)]\#(usageField)}"#.utf8))
        case .streaming:
            let deltaJSON = try #require(String(data: JSONEncoder().encode(delta), encoding: .utf8))
            let events = [
                #"{"type":"message_start","message":{"content":[]\#(usageField)}}"#,
                #"{"type":"content_block_start","index":0,"content_block":\#(blockJSON)}"#,
                #"{"type":"content_block_delta","index":0,"delta":\#(deltaJSON)}"#,
                #"{"type":"content_block_stop","index":0}"#,
                #"{"type":"message_delta"\#(usageField)}"#,
                #"{"type":"message_stop"}"#
            ]
            return HTTPTestResponse(
                body: Data(events.map { "data: \($0)\n\n" }.joined().utf8),
                headers: ["Content-Type": "text/event-stream"]
            )
        }
    }
}

func withAnthropicContextClient(
    responses: [HTTPTestResponse],
    operation: (AnthropicClient, URL) async throws -> Void
) async throws {
    let baseURL = try #require(URL(string: "https://anthropic-context-\(UUID().uuidString).test/v1"))
    let url = baseURL.appendingPathComponent("messages")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HTTPTestURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let sequence = HTTPTestResponseSequence(responses: responses)
    HTTPTestURLProtocol.register(url: url) { _ in try sequence.nextResponse(url: url) }
    defer { HTTPTestURLProtocol.unregister(url: url) }
    let client = try AnthropicClient(
        apiKey: "test-key", model: "claude-sonnet-4-6", contextWindowSize: 1000,
        baseURL: baseURL, session: session, retryPolicy: .none, cachingEnabled: true
    )
    try await operation(client, url)
}
