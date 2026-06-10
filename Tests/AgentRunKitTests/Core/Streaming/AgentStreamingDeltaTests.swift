@testable import AgentRunKit
import Foundation
import Testing

struct AgentStreamingFinishDecodingTests {
    @Test
    func malformedFinishArgumentsThrowsInStreaming() async throws {
        let deltas: [StreamDelta] = [
            .content("Here is your answer"),
            .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: "not valid json at all"),
            .finished(usage: TokenUsage(input: 10, output: 5))
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        do {
            for try await _ in agent.stream(userMessage: "Hello", context: EmptyContext()) {}
            Issue.record("Expected finishDecodingFailed error")
        } catch let error as AgentError {
            guard case let .finishDecodingFailed(message) = error else {
                Issue.record("Expected finishDecodingFailed, got \(error)")
                return
            }
            #expect(!message.isEmpty)
        }
    }

    @Test
    func malformedFinishWithMissingContentFieldThrows() async throws {
        let deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"reason": "completed"}"#),
            .finished(usage: nil)
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        do {
            for try await _ in agent.stream(userMessage: "Hi", context: EmptyContext()) {}
            Issue.record("Expected finishDecodingFailed error for missing content")
        } catch let error as AgentError {
            guard case .finishDecodingFailed = error else {
                Issue.record("Expected finishDecodingFailed, got \(error)")
                return
            }
        }
    }

    @Test
    func truncatedJSONInFinishThrows() async throws {
        let deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "incomplete"#),
            .finished(usage: nil)
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        do {
            for try await _ in agent.stream(userMessage: "Hi", context: EmptyContext()) {}
            Issue.record("Expected finishDecodingFailed error for truncated JSON")
        } catch let error as AgentError {
            guard case .finishDecodingFailed = error else {
                Issue.record("Expected finishDecodingFailed, got \(error)")
                return
            }
        }
    }
}

struct AgentStreamingOutOfOrderDeltaTests {
    @Test
    func interleavedDeltasForMultipleToolCalls() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )

        let firstDeltas: [StreamDelta] = [
            .toolCallDelta(index: 0, arguments: #"{"mes"#),
            .toolCallDelta(index: 1, arguments: #"{"mes"#),
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"sage":"first"}"#),
            .toolCallStart(index: 1, id: "call_2", name: "echo", kind: .function),
            .toolCallDelta(index: 1, arguments: #"sage":"second"}"#),
            .finished(usage: nil)
        ]

        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_3", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: nil)
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, secondDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])

        var toolResults: [String: String] = [:]
        for try await event in agent.stream(userMessage: "Hi", context: EmptyContext()) {
            if case let .toolCallCompleted(id, _, result) = event.kind {
                toolResults[id] = result.content
            }
        }

        #expect(toolResults.count == 2)
        #expect(toolResults["call_1"]?.contains("Echo: first") == true)
        #expect(toolResults["call_2"]?.contains("Echo: second") == true)
    }

    @Test
    func allDeltasBeforeStartAreBuffered() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Got: \(params.message)") }
        )

        let firstDeltas: [StreamDelta] = [
            .toolCallDelta(index: 0, arguments: #"{"#),
            .toolCallDelta(index: 0, arguments: #""message""#),
            .toolCallDelta(index: 0, arguments: #":"#),
            .toolCallDelta(index: 0, arguments: #""test""#),
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"}"#),
            .finished(usage: nil)
        ]

        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: nil)
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, secondDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])

        var toolResult: String?
        for try await event in agent.stream(userMessage: "Hi", context: EmptyContext()) {
            if case let .toolCallCompleted(_, name, result) = event.kind, name == "echo" {
                toolResult = result.content
            }
        }

        #expect(toolResult?.contains("Got: test") == true)
    }

    @Test
    func outOfOrderWithThreeToolCalls() async throws {
        let addTool = try Tool<AddParams, AddOutput, EmptyContext>(
            name: "add",
            description: "Adds numbers",
            executor: { params, _ in AddOutput(sum: params.lhs + params.rhs) }
        )

        let firstDeltas: [StreamDelta] = [
            .toolCallDelta(index: 2, arguments: #"{"lhs":5,"#),
            .toolCallDelta(index: 0, arguments: #"{"lhs":1,"#),
            .toolCallDelta(index: 1, arguments: #"{"lhs":3,"#),
            .toolCallStart(index: 1, id: "call_2", name: "add", kind: .function),
            .toolCallStart(index: 0, id: "call_1", name: "add", kind: .function),
            .toolCallDelta(index: 1, arguments: #""rhs":4}"#),
            .toolCallStart(index: 2, id: "call_3", name: "add", kind: .function),
            .toolCallDelta(index: 0, arguments: #""rhs":2}"#),
            .toolCallDelta(index: 2, arguments: #""rhs":6}"#),
            .finished(usage: nil)
        ]

        let secondDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_4", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: nil)
        ]

        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, secondDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [addTool])

        var sums: [Int] = []
        for try await event in agent.stream(userMessage: "Add", context: EmptyContext()) {
            if case let .toolCallCompleted(_, name, result) = event.kind, name == "add" {
                let digitsOnly = result.content.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                if let sum = Int(digitsOnly) {
                    sums.append(sum)
                }
            }
        }

        #expect(sums.count == 3)
        #expect(sums.contains(3))
        #expect(sums.contains(7))
        #expect(sums.contains(11))
    }
}

struct AgentStreamingOrphanedDeltaTests {
    @Test
    func orphanedDeltasWithoutStartThrowsError() async throws {
        let deltas: [StreamDelta] = [
            .toolCallDelta(index: 5, arguments: #"{"message":"orphaned"}"#),
            .finished(usage: nil)
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        do {
            for try await _ in agent.stream(userMessage: "Hi", context: EmptyContext()) {}
            Issue.record("Expected malformedStream error for orphaned deltas")
        } catch let error as AgentError {
            guard case let .llmError(.streamFailed(.malformedStream(reason, _))) = error else {
                Issue.record("Expected malformedStream, got \(error)")
                return
            }
            guard case let .orphanedToolCallArguments(indices) = reason else {
                Issue.record("Expected orphanedToolCallArguments, got \(reason)")
                return
            }
            #expect(indices == [5])
        }
    }

    @Test
    func multipleOrphanedIndicesReported() async throws {
        let deltas: [StreamDelta] = [
            .toolCallDelta(index: 2, arguments: #"{"a":1}"#),
            .toolCallDelta(index: 7, arguments: #"{"b":2}"#),
            .toolCallDelta(index: 3, arguments: #"{"c":3}"#),
            .finished(usage: nil)
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        do {
            for try await _ in agent.stream(userMessage: "Hi", context: EmptyContext()) {}
            Issue.record("Expected malformedStream error")
        } catch let error as AgentError {
            guard case let .llmError(.streamFailed(.malformedStream(reason, _))) = error else {
                Issue.record("Expected malformedStream, got \(error)")
                return
            }
            guard case let .orphanedToolCallArguments(indices) = reason else {
                Issue.record("Expected orphanedToolCallArguments, got \(reason)")
                return
            }
            #expect(indices == [2, 3, 7])
        }
    }

    @Test
    func mixedOrphanedAndValidDeltasThrows() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )

        let deltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"valid"}"#),
            .toolCallDelta(index: 5, arguments: #"{"orphaned":true}"#),
            .finished(usage: nil)
        ]
        let client = StreamingMockLLMClient(streamSequences: [deltas])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])

        do {
            for try await _ in agent.stream(userMessage: "Hi", context: EmptyContext()) {}
            Issue.record("Expected malformedStream error")
        } catch let error as AgentError {
            guard case let .llmError(.streamFailed(.malformedStream(reason, _))) = error else {
                Issue.record("Expected malformedStream, got \(error)")
                return
            }
            guard case let .orphanedToolCallArguments(indices) = reason else {
                Issue.record("Expected orphanedToolCallArguments, got \(reason)")
                return
            }
            #expect(indices == [5])
        }
    }
}

private struct EchoParams: Codable, SchemaProviding {
    let message: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

private struct EchoOutput: Codable {
    let echoed: String
}

private struct AddParams: Codable, SchemaProviding {
    let lhs: Int
    let rhs: Int
    static var jsonSchema: JSONSchema {
        .object(properties: ["lhs": .integer(), "rhs": .integer()], required: ["lhs", "rhs"])
    }
}

private struct AddOutput: Codable {
    let sum: Int
}
