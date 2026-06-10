@testable import AgentRunKit
import Foundation
import Testing

let responsesStreamingEmptyCompletedJSON =
    #"{"type":"response.completed","response":{"id":"resp_001","status":"completed","output":[],"#
        + #""usage":{"input_tokens":10,"output_tokens":5}}}"#

func makeResponsesStreamingClient() -> ResponsesAPIClient {
    ResponsesAPIClient(
        apiKey: "test-key",
        model: "gpt-4.1",
        baseURL: ResponsesAPIClient.openAIBaseURL
    )
}

func responsesSSELine(_ json: String) -> String {
    "data: \(json.replacingOccurrences(of: "\n", with: ""))"
}

func collectResponsesStreamDeltas(
    client: ResponsesAPIClient,
    lines: [String]
) async throws -> [StreamDelta] {
    var collected: [StreamDelta] = []
    for element in try await collectRunStreamElements(client: client, lines: lines) {
        guard case let .delta(delta) = element else { continue }
        collected.append(delta)
    }
    return collected
}

func streamedAssistantMessage(
    client: ResponsesAPIClient,
    lines: [String]
) async throws -> AssistantMessage {
    let elements = try await collectRunStreamElements(client: client, lines: lines)
    let streamClient = ContinuityStreamingMockLLMClient(streamSequences: [elements])
    let processor = StreamProcessor(
        client: streamClient, toolDefinitions: [], policy: .chat,
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
    return iteration.toAssistantMessage()
}

func collectRunStreamElements(
    client: ResponsesAPIClient,
    lines: [String]
) async throws -> [RunStreamElement] {
    let result = await collectRunStreamElementsResult(client: client, lines: lines)
    if let error = result.error {
        throw error
    }
    return result.elements
}

func collectRunStreamElementsResult(
    client: ResponsesAPIClient,
    lines: [String]
) async -> (elements: [RunStreamElement], error: (any Error)?) {
    let allBytes = lines.joined(separator: "\n\n").appending("\n\n")
    let (byteStream, byteContinuation) = AsyncStream<UInt8>.makeStream()
    for byte in Array(allBytes.utf8) {
        byteContinuation.yield(byte)
    }
    byteContinuation.finish()

    let controlled = ControlledByteStream(stream: byteStream)
    let streamPair = AsyncThrowingStream<RunStreamElement, Error>.makeStream()
    let task = Task {
        do {
            try await client.processRunStreamBytes(
                bytes: controlled,
                messagesCount: 0,
                stallTimeout: nil,
                continuation: streamPair.continuation
            )
        } catch {
            streamPair.continuation.finish(throwing: error)
        }
    }

    var elements: [RunStreamElement] = []
    do {
        for try await element in streamPair.stream {
            elements.append(element)
        }
        _ = await task.result
        return (elements, nil)
    } catch {
        _ = await task.result
        return (elements, error)
    }
}
