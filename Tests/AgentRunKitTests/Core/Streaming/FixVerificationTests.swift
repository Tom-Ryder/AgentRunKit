@testable import AgentRunKit
import Foundation
import Testing

struct StreamingFinishDecodingTests {
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

struct OptionalArrayElementSchemaTests {
    @Test
    func arrayOfOptionalStringsProducesCorrectSchema() throws {
        struct Params: Codable {
            let values: [String?]
        }
        let schema = try SchemaDecoder.decode(Params.self)
        guard case let .object(properties, _, _) = schema else {
            Issue.record("Expected object schema, got \(schema)")
            return
        }
        guard let valuesSchema = properties["values"] else {
            Issue.record("Expected values property, got properties: \(properties)")
            return
        }
        guard case let .array(itemSchema, _) = valuesSchema else {
            Issue.record("Expected array schema for values, got \(valuesSchema)")
            return
        }
        guard case let .anyOf(options) = itemSchema else {
            Issue.record("Expected anyOf schema for nullable array items, got \(itemSchema)")
            return
        }
        #expect(options.contains(.string()))
        #expect(options.contains(.null))
        #expect(options.count == 2)
    }

    @Test
    func arrayOfOptionalIntsProducesCorrectSchema() throws {
        struct Params: Codable {
            let counts: [Int?]
        }
        let schema = try SchemaDecoder.decode(Params.self)
        guard case let .object(properties, _, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        guard case let .array(itemSchema, _) = properties["counts"] else {
            Issue.record("Expected array schema for counts")
            return
        }
        guard case let .anyOf(options) = itemSchema else {
            Issue.record("Expected anyOf schema for nullable array items, got \(itemSchema)")
            return
        }
        #expect(options.contains(.integer()))
        #expect(options.contains(.null))
        #expect(options.count == 2)
    }

    @Test
    func arrayOfOptionalDoublesProducesCorrectSchema() throws {
        struct Params: Codable {
            let scores: [Double?]
        }
        let schema = try SchemaDecoder.decode(Params.self)
        guard case let .object(properties, _, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        guard case let .array(itemSchema, _) = properties["scores"] else {
            Issue.record("Expected array schema for scores")
            return
        }
        guard case let .anyOf(options) = itemSchema else {
            Issue.record("Expected anyOf schema for nullable array items, got \(itemSchema)")
            return
        }
        #expect(options.contains(.number()))
        #expect(options.contains(.null))
    }

    @Test
    func arrayOfOptionalBoolsProducesCorrectSchema() throws {
        struct Params: Codable {
            let flags: [Bool?]
        }
        let schema = try SchemaDecoder.decode(Params.self)
        guard case let .object(properties, _, _) = schema else {
            Issue.record("Expected object schema")
            return
        }
        guard case let .array(itemSchema, _) = properties["flags"] else {
            Issue.record("Expected array schema for flags")
            return
        }
        guard case let .anyOf(options) = itemSchema else {
            Issue.record("Expected anyOf schema for nullable array items, got \(itemSchema)")
            return
        }
        #expect(options.contains(.boolean()))
        #expect(options.contains(.null))
    }

    @Test
    func mixedOptionalAndNonOptionalArrays() throws {
        struct Params: Codable {
            let required: [String]
            let nullable: [String?]
        }
        let schema = try SchemaDecoder.decode(Params.self)
        guard case let .object(properties, _, _) = schema else {
            Issue.record("Expected object schema")
            return
        }

        guard case let .array(requiredItems, _) = properties["required"] else {
            Issue.record("Expected array schema for required")
            return
        }
        #expect(requiredItems == .string())

        guard case let .array(nullableItems, _) = properties["nullable"] else {
            Issue.record("Expected array schema for nullable")
            return
        }
        guard case let .anyOf(options) = nullableItems else {
            Issue.record("Expected anyOf for nullable items")
            return
        }
        #expect(options.contains(.string()))
        #expect(options.contains(.null))
    }
}

struct InterleavedOutOfOrderDeltaTests {
    @Test
    func interleavedDeltasForMultipleToolCalls() async throws {
        let echoTool = try Tool<InterleavedEchoParams, InterleavedEchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in InterleavedEchoOutput(echoed: "Echo: \(params.message)") }
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
        let echoTool = try Tool<InterleavedEchoParams, InterleavedEchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in InterleavedEchoOutput(echoed: "Got: \(params.message)") }
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
        let addTool = try Tool<InterleavedAddParams, InterleavedAddOutput, EmptyContext>(
            name: "add",
            description: "Adds numbers",
            executor: { params, _ in InterleavedAddOutput(sum: params.lhs + params.rhs) }
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

private struct InterleavedEchoParams: Codable, SchemaProviding {
    let message: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

private struct InterleavedEchoOutput: Codable {
    let echoed: String
}

private struct InterleavedAddParams: Codable, SchemaProviding {
    let lhs: Int
    let rhs: Int
    static var jsonSchema: JSONSchema {
        .object(properties: ["lhs": .integer(), "rhs": .integer()], required: ["lhs", "rhs"])
    }
}

private struct InterleavedAddOutput: Codable {
    let sum: Int
}

struct OrphanedStreamDeltaTests {
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
        let echoTool = try Tool<InterleavedEchoParams, InterleavedEchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in InterleavedEchoOutput(echoed: "Echo: \(params.message)") }
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

struct ConflictingAssistantContinuityTests {
    @Test
    func conflictingFinalizedContinuityThrowsMalformedStream() async throws {
        let first = AssistantContinuity(
            substrate: .responses,
            payload: .object(["response_id": .string("resp_123")])
        )
        let second = AssistantContinuity(
            substrate: .responses,
            payload: .object(["response_id": .string("resp_456")])
        )
        let client = ContinuityStreamingMockLLMClient(streamSequences: [[
            .finalizedContinuity(first),
            .finalizedContinuity(second),
        ]])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        do {
            for try await _ in agent.stream(userMessage: "Hi", context: EmptyContext()) {}
            Issue.record("Expected malformedStream error")
        } catch let error as AgentError {
            guard case let .llmError(.streamFailed(.malformedStream(reason, _))) = error else {
                Issue.record("Expected malformedStream, got \(error)")
                return
            }
            #expect(reason == .conflictingAssistantContinuity)
        }
    }
}

struct SSEEventParserVerificationTests {
    @Test
    func emitsPayloadWithSpace() throws {
        var parser = SSEEventParser()
        #expect(parser.appendLine("data: {\"content\":\"hello\"}") == nil)
        let parsed = parser.appendLine("")
        let event = try #require(parsed)
        #expect(event.data == "{\"content\":\"hello\"}")
    }

    @Test
    func emitsPayloadWithoutSpace() throws {
        var parser = SSEEventParser()
        #expect(parser.appendLine("data:{\"content\":\"hello\"}") == nil)
        let parsed = parser.appendLine("")
        let event = try #require(parsed)
        #expect(event.data == "{\"content\":\"hello\"}")
    }

    @Test
    func preservesDoneMarkerWithSpace() throws {
        var parser = SSEEventParser()
        #expect(parser.appendLine("data: [DONE]") == nil)
        let parsed = parser.appendLine("")
        let event = try #require(parsed)
        #expect(event.data == "[DONE]")
    }

    @Test
    func preservesDoneMarkerWithoutSpace() throws {
        var parser = SSEEventParser()
        #expect(parser.appendLine("data:[DONE]") == nil)
        let parsed = parser.appendLine("")
        let event = try #require(parsed)
        #expect(event.data == "[DONE]")
    }

    @Test
    func ignoresNonDataEventWithoutDispatch() {
        var parser = SSEEventParser()
        #expect(parser.appendLine(": comment") == nil)
        #expect(parser.appendLine("event: message") == nil)
        #expect(parser.appendLine("") == nil)
        #expect(parser.appendLine("id: 123") == nil)
        #expect(parser.finish() == nil)
    }

    @Test
    func emitsEmptyPayload() throws {
        var parser = SSEEventParser()
        #expect(parser.appendLine("data:") == nil)
        let parsed = parser.appendLine("")
        let event = try #require(parsed)
        #expect(event.data == "")
    }

    @Test
    func combinesMultilinePayloadAndMetadata() throws {
        var parser = SSEEventParser()
        #expect(parser.appendLine("event: message") == nil)
        #expect(parser.appendLine("id: 123") == nil)
        #expect(parser.appendLine("retry: 250") == nil)
        #expect(parser.appendLine("data: first") == nil)
        #expect(parser.appendLine("data: second") == nil)
        let parsed = parser.appendLine("")
        let event = try #require(parsed)
        #expect(event.event == "message")
        #expect(event.id == "123")
        #expect(event.retry == 250)
        #expect(event.data == "first\nsecond")
    }
}
