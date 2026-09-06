@testable import AgentRunKit
import Foundation
import Testing

struct GeminiResponseParsingTests {
    private func makeClient() -> GeminiClient {
        GeminiClient(apiKey: "test-key", model: "gemini-2.5-pro")
    }

    @Test
    func textResponse() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [{"text": "Hello there!"}]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 100,
                "candidatesTokenCount": 50,
                "totalTokenCount": 150
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8), provider: .gemini)
        #expect(msg.content == "Hello there!")
        #expect(msg.toolCalls.isEmpty)
        #expect(msg.tokenUsage?.input == 100)
        #expect(msg.tokenUsage?.output == 50)
    }

    @Test
    func functionCallResponse() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [
                        {"text": "Let me check."},
                        {"functionCall": {"id": "call_01", "name": "get_weather", "args": {"city": "NYC"}}}
                    ]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 50,
                "candidatesTokenCount": 30
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8), provider: .gemini)
        #expect(msg.content == "Let me check.")
        #expect(msg.toolCalls.count == 1)
        #expect(msg.toolCalls[0].id == "call_01")
        #expect(msg.toolCalls[0].name == "get_weather")
        #expect(msg.toolCalls[0].arguments.contains("NYC"))
    }

    @Test
    func thinkingResponse() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [
                        {"text": "Let me reason...", "thought": true, "thoughtSignature": "sig123"},
                        {"text": "The answer is 42."}
                    ]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 100,
                "candidatesTokenCount": 200,
                "thoughtsTokenCount": 50
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8), provider: .gemini)
        #expect(msg.content == "The answer is 42.")
        #expect(msg.reasoning?.content == "Let me reason...")
        #expect(msg.reasoningDetails?.count == 1)
        if case let .object(dict) = msg.reasoningDetails?[0] {
            #expect(dict["type"] == .string("thinking"))
            #expect(dict["thinking"] == .string("Let me reason..."))
            #expect(dict["signature"] == .string("sig123"))
        } else {
            Issue.record("Expected object in reasoning details")
        }
        #expect(msg.tokenUsage?.reasoning == 50)
        #expect(msg.tokenUsage?.output == 200)
    }

    @Test
    func multipleFunctionCalls() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [
                        {"functionCall": {"id": "call_a", "name": "search", "args": {"q": "first"}}},
                        {"functionCall": {"id": "call_b", "name": "lookup", "args": {"id": 42}}}
                    ]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 50,
                "candidatesTokenCount": 30
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8), provider: .gemini)
        #expect(msg.toolCalls.count == 2)
        #expect(msg.toolCalls[0].id == "call_a")
        #expect(msg.toolCalls[0].name == "search")
        #expect(msg.toolCalls[1].id == "call_b")
        #expect(msg.toolCalls[1].name == "lookup")
    }

    @Test
    func functionCallWithoutId() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [
                        {"functionCall": {"name": "get_weather", "args": {"city": "NYC"}}}
                    ]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 50,
                "candidatesTokenCount": 30
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8), provider: .gemini)
        #expect(msg.toolCalls.count == 1)
        #expect(msg.toolCalls[0].id == "gemini_call_0")
        #expect(msg.toolCalls[0].name == "get_weather")
    }

    @Test
    func errorResponse() throws {
        let json = """
        {
            "error": {
                "code": 400,
                "message": "Invalid request",
                "status": "INVALID_ARGUMENT"
            }
        }
        """
        do {
            _ = try makeClient().parseResponse(Data(json.utf8), provider: .gemini)
            Issue.record("Expected error")
        } catch let error as AgentError {
            guard case let .llmError(transport) = error,
                  case let .providerError(provider, code, message) = transport
            else {
                Issue.record("Expected providerError, got \(error)")
                return
            }
            #expect(provider == .gemini)
            #expect(code == "INVALID_ARGUMENT")
            #expect(message == "Invalid request")
        }
    }

    @Test
    func usageMapping() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [{"text": "Hi"}]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 200,
                "candidatesTokenCount": 100
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8), provider: .gemini)
        #expect(msg.tokenUsage == TokenUsage(input: 200, output: 100, cacheRead: 0))
    }

    @Test
    func emptyCandidatesThrows() {
        let json = """
        {
            "candidates": [],
            "usageMetadata": {
                "promptTokenCount": 10,
                "candidatesTokenCount": 0
            }
        }
        """
        #expect(throws: AgentError.self) {
            _ = try makeClient().parseResponse(Data(json.utf8), provider: .gemini)
        }
    }

    @Test
    func missingPartsParsesToEmptyString() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model"
                },
                "finishReason": "SAFETY"
            }],
            "usageMetadata": {
                "promptTokenCount": 10,
                "candidatesTokenCount": 0
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8), provider: .gemini)
        #expect(msg.content == "")
        #expect(msg.toolCalls.isEmpty)
    }

    @Test
    func emptyContentParsesToEmptyString() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": []
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 10,
                "candidatesTokenCount": 0
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8), provider: .gemini)
        #expect(msg.content == "")
        #expect(msg.toolCalls.isEmpty)
    }

    @Test
    func interleavedThinkingAndFunctionCall() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [
                        {"text": "Think first", "thought": true, "thoughtSignature": "s1"},
                        {"text": "Checking."},
                        {"functionCall": {"id": "call_02", "name": "search", "args": {"q": "test"}}},
                        {"text": "Think again", "thought": true, "thoughtSignature": "s2"},
                        {"text": "More text."}
                    ]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 80,
                "candidatesTokenCount": 120,
                "thoughtsTokenCount": 40
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8), provider: .gemini)
        #expect(msg.content == "Checking.More text.")
        #expect(msg.toolCalls.count == 1)
        #expect(msg.reasoning?.content == "Think first\nThink again")
        #expect(msg.reasoningDetails?.count == 2)
        #expect(msg.tokenUsage?.reasoning == 40)
        #expect(msg.tokenUsage?.output == 120)
    }

    @Test
    func cachedContentTokenCountMappedToCacheRead() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [{"text": "Hi"}]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 200,
                "candidatesTokenCount": 100,
                "cachedContentTokenCount": 150
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8), provider: .gemini)
        #expect(msg.tokenUsage?.cacheRead == 150)
    }

    @Test
    func functionCallWithoutArgs() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [
                        {"functionCall": {"id": "call_01", "name": "get_status"}}
                    ]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 50,
                "candidatesTokenCount": 10
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8), provider: .gemini)
        #expect(msg.toolCalls.count == 1)
        #expect(msg.toolCalls[0].arguments == "{}")
    }

    @Test
    func malformedResponseThrowsDecodingError() {
        let client = makeClient()
        let garbage = Data("not json at all".utf8)

        do {
            _ = try client.parseResponse(garbage, provider: .gemini)
            Issue.record("Expected error")
        } catch let error as AgentError {
            guard case let .llmError(transport) = error,
                  case .decodingFailed = transport
            else {
                Issue.record("Expected .decodingFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AgentError, got \(error)")
        }
    }

    @Test(arguments: [
        #"{"zeta":[{"zeta":true,"alpha":"雪"},{"zeta":false,"alpha":"first"}],"alpha":"{ \"z\": 1, \"a\": 2 }"}"#,
        #"{"alpha":"{ \"z\": 1, \"a\": 2 }","zeta":[{"alpha":"雪","zeta":true},{"alpha":"first","zeta":false}]}"#
    ])
    func objectArgumentsUseDeterministicOrder(inputJSON: String) throws {
        let json = #"{"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"#
            + #""id":"call_order","name":"inspect","args":\#(inputJSON)}}]},"finishReason":"STOP"}]}"#

        let message = try makeClient().parseResponse(Data(json.utf8), provider: .gemini)
        let call = try #require(message.toolCalls.first)
        let expected = #"{"alpha":"{ \"z\": 1, \"a\": 2 }","zeta":[{"alpha":"雪","zeta":true},"#
            + #"{"alpha":"first","zeta":false}]}"#

        #expect(call.arguments == expected)
    }

    @Test
    func toolCallArgumentsRoundTripAsJSONObject() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [
                        {"functionCall": {"id": "call_rt", "name": "get_weather",
                         "args": {"city": "NYC", "units": "celsius"}}}
                    ]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 40,
                "candidatesTokenCount": 20
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8), provider: .gemini)
        #expect(msg.toolCalls.count == 1)
        #expect(msg.toolCalls[0].id == "call_rt")
        #expect(msg.toolCalls[0].name == "get_weather")

        let parsedArgs = try JSONDecoder().decode(
            [String: String].self, from: Data(msg.toolCalls[0].arguments.utf8)
        )
        #expect(parsedArgs["city"] == "NYC")
        #expect(parsedArgs["units"] == "celsius")

        let (_, mapped) = try GeminiMessageMapper.mapMessages([.assistant(msg)])
        let modelParts = mapped[0].parts
        let toolPart = modelParts.first { $0.functionCall != nil }
        #expect(toolPart?.functionCall?.id == "call_rt")
        #expect(toolPart?.functionCall?.name == "get_weather")
        guard case let .object(inputDict) = toolPart?.functionCall?.args else {
            Issue.record("Expected args to be a JSON object")
            return
        }
        #expect(inputDict["city"] == .string("NYC"))
        #expect(inputDict["units"] == .string("celsius"))
    }
}

struct GeminiFunctionCallReasoningDetailsTests {
    private func makeClient() -> GeminiClient {
        GeminiClient(apiKey: "test-key", model: "gemini-2.5-pro")
    }

    @Test
    func functionCallThoughtSignatureIsPreservedInReasoningDetails() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "role": "model",
                    "parts": [
                        {
                            "functionCall": {"id": "call_sig", "name": "search", "args": {"q": "test"}},
                            "thoughtSignature": "sig_fc"
                        }
                    ]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 40,
                "candidatesTokenCount": 20
            }
        }
        """
        let msg = try makeClient().parseResponse(Data(json.utf8), provider: .gemini)

        #expect(msg.toolCalls.count == 1)
        #expect(msg.toolCalls[0].id == "call_sig")
        #expect(msg.reasoningDetails?.count == 1)
        if case let .object(dict) = msg.reasoningDetails?[0] {
            #expect(dict["type"] == .string("gemini.function_call"))
            #expect(dict["tool_call_id"] == .string("call_sig"))
            #expect(dict["thought_signature"] == .string("sig_fc"))
        } else {
            Issue.record("Expected function-call reasoning detail")
        }
    }
}

extension GeminiResponseParsingTests {
    @Test(arguments: [
        (nil, nil), ("null", nil), ("{}", TokenUsage(cacheRead: 0)),
        (#"{"promptTokenCount":null,"candidatesTokenCount":null,"thoughtsTokenCount":null,"#
            + #""cachedContentTokenCount":null}"#, TokenUsage(cacheRead: 0)),
        (#"{"promptTokenCount":1124,"totalTokenCount":1171,"thoughtsTokenCount":47}"#,
         TokenUsage(input: 1124, reasoning: 47, cacheRead: 0)),
        (#"{"promptTokenCount":100,"candidatesTokenCount":20,"cachedContentTokenCount":0}"#,
         TokenUsage(input: 100, output: 20, cacheRead: 0)),
        (#"{"promptTokenCount":100,"candidatesTokenCount":20,"cachedContentTokenCount":null}"#,
         TokenUsage(input: 100, output: 20, cacheRead: 0)),
        (#"{"promptTokenCount":100,"candidatesTokenCount":20,"cachedContentTokenCount":80}"#,
         TokenUsage(input: 100, output: 20, cacheRead: 80)),
        (#"{"promptTokenCount":100,"cachedContentTokenCount":101}"#, nil)
    ] as [(String?, TokenUsage?)])
    func metadataPresenceAndScalarDefaults(metadata: String?, expected: TokenUsage?) throws {
        let metadataField = metadata.map { #", "usageMetadata":\#($0)"# } ?? ""
        let json = #"{"candidates":[{"content":{"role":"model","parts":[{"text":"Checking"},"#
            + #"{"functionCall":{"id":"call_1","name":"lookup","args":{}},"thoughtSignature":"opaque=="}]},"#
            + #""finishReason":"STOP"}]\#(metadataField)}"#
        let message = try makeClient().parseResponse(Data(json.utf8), provider: .gemini)
        #expect(message.content == "Checking")
        #expect(message.toolCalls == [ToolCall(id: "call_1", name: "lookup", arguments: "{}")])
        #expect(message.reasoningDetails == [.object([
            "type": .string("gemini.function_call"), "tool_call_id": .string("call_1"),
            "thought_signature": .string("opaque==")
        ])])
        #expect(message.tokenUsage == expected)
    }

    @Test(arguments: ["promptTokenCount", "candidatesTokenCount", "thoughtsTokenCount", "cachedContentTokenCount"], [
        "-1", #""1""#, "true", "1.5", "9223372036854775808"
    ])
    func malformedUsageMetadataThrows(key: String, value: String) throws {
        let json = #"{"candidates":[{"content":{"parts":[{"text":"Answer"}]},"finishReason":"STOP"}],"#
            + #""usageMetadata":{"\#(key)":\#(value)}}"#
        do {
            _ = try makeClient().parseResponse(Data(json.utf8), provider: .gemini)
            Issue.record("Expected malformed usage metadata to fail")
        } catch let AgentError.llmError(.decodingFailed(description)) {
            #expect(description.contains("usageMetadata"))
            #expect(description.contains(key))
        }
    }
}
