import Foundation
import Testing

@testable import AgentRunKit

@Suite
struct OpenAIClientResponseTests {
    @Test
    func responseDecodesCorrectly() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": "Hello there!"
                },
                "finish_reason": "stop"
            }],
            "usage": {
                "prompt_tokens": 100,
                "completion_tokens": 50
            }
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let msg = try client.parseResponse(Data(json.utf8))

        #expect(msg.content == "Hello there!")
        #expect(msg.toolCalls.isEmpty)
        #expect(msg.tokenUsage?.input == 100)
        #expect(msg.tokenUsage?.output == 50)
        #expect(msg.tokenUsage?.reasoning == 0)
    }

    @Test
    func responseWithToolCallsDecodes() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": null,
                    "tool_calls": [{
                        "id": "call_abc123",
                        "type": "function",
                        "function": {
                            "name": "get_weather",
                            "arguments": "{\\"city\\": \\"NYC\\"}"
                        }
                    }]
                },
                "finish_reason": "tool_calls"
            }],
            "usage": {
                "prompt_tokens": 50,
                "completion_tokens": 25
            }
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let msg = try client.parseResponse(Data(json.utf8))

        #expect(msg.content == "")
        #expect(msg.toolCalls.count == 1)
        #expect(msg.toolCalls[0].id == "call_abc123")
        #expect(msg.toolCalls[0].name == "get_weather")
        #expect(msg.toolCalls[0].arguments == "{\"city\": \"NYC\"}")
    }

    @Test
    func responseWithMultipleToolCallsDecodes() throws {
        func toolCall(_ id: String, _ name: String, _ args: String) -> String {
            #"{"id":"\#(id)","type":"function","function":{"name":"\#(name)","arguments":"\#(args)"}}"#
        }
        let tc1 = toolCall("call_001", "get_weather", #"{\"city\":\"NYC\"}"#)
        let tc2 = toolCall("call_002", "get_weather", #"{\"city\":\"LA\"}"#)
        let tc3 = toolCall("call_003", "get_time", #"{\"timezone\":\"PST\"}"#)
        let json = """
        {"choices":[{"message":{"role":"assistant","content":"Checking",\
        "tool_calls":[\(tc1),\(tc2),\(tc3)]},"finish_reason":"tool_calls"}],\
        "usage":{"prompt_tokens":80,"completion_tokens":40}}
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let msg = try client.parseResponse(Data(json.utf8))

        #expect(msg.content == "Checking")
        #expect(msg.toolCalls.count == 3)
        #expect(msg.toolCalls[0] == ToolCall(id: "call_001", name: "get_weather", arguments: #"{"city":"NYC"}"#))
        #expect(msg.toolCalls[1] == ToolCall(id: "call_002", name: "get_weather", arguments: #"{"city":"LA"}"#))
        #expect(msg.toolCalls[2] == ToolCall(id: "call_003", name: "get_time", arguments: #"{"timezone":"PST"}"#))
    }

    @Test
    func responseWithReasoningTokensDecodes() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": "I think..."
                },
                "finish_reason": "stop"
            }],
            "usage": {
                "prompt_tokens": 100,
                "completion_tokens": 150,
                "completion_tokens_details": {
                    "reasoning_tokens": 100
                }
            }
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let msg = try client.parseResponse(Data(json.utf8))

        #expect(msg.tokenUsage?.input == 100)
        #expect(msg.tokenUsage?.output == 50)
        #expect(msg.tokenUsage?.reasoning == 100)
    }

    @Test
    func responseWithoutUsageDefaultsToZero() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": "Hi"
                }
            }]
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let msg = try client.parseResponse(Data(json.utf8))

        #expect(msg.tokenUsage == nil)
    }

    @Test
    func responseWithNoChoicesThrows() throws {
        let json = """
        {
            "choices": []
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        do {
            _ = try client.parseResponse(Data(json.utf8))
            Issue.record("Expected error")
        } catch let error as AgentError {
            guard case let .llmError(transportError) = error else {
                Issue.record("Expected llmError, got \(error)")
                return
            }
            #expect(transportError == .noChoices)
        }
    }

    @Test
    func invalidJSONThrowsDecodingError() throws {
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        do {
            _ = try client.parseResponse(Data("not json".utf8))
            Issue.record("Expected error")
        } catch let error as AgentError {
            guard case let .llmError(transportError) = error else {
                Issue.record("Expected llmError, got \(error)")
                return
            }
            if case let .decodingFailed(desc) = transportError {
                #expect(desc.contains("expected"))
            } else {
                Issue.record("Expected decodingFailed, got \(transportError)")
            }
        }
    }

    @Test
    func responseWithReasoningFieldDecodes() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": "The answer is 42.",
                    "reasoning": "Let me think step by step..."
                },
                "finish_reason": "stop"
            }],
            "usage": {
                "prompt_tokens": 50,
                "completion_tokens": 100
            }
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let msg = try client.parseResponse(Data(json.utf8))

        #expect(msg.content == "The answer is 42.")
        #expect(msg.reasoning?.content == "Let me think step by step...")
        #expect(msg.reasoning?.signature == nil)
    }

    @Test
    func responseWithReasoningContentFieldDecodes() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": "Result",
                    "reasoning_content": "Alternative field name reasoning..."
                },
                "finish_reason": "stop"
            }],
            "usage": {
                "prompt_tokens": 50,
                "completion_tokens": 100
            }
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let msg = try client.parseResponse(Data(json.utf8))

        #expect(msg.content == "Result")
        #expect(msg.reasoning?.content == "Alternative field name reasoning...")
    }

    @Test
    func responseWithoutReasoningHasNilReasoning() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": "Simple response"
                },
                "finish_reason": "stop"
            }],
            "usage": {
                "prompt_tokens": 50,
                "completion_tokens": 20
            }
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let msg = try client.parseResponse(Data(json.utf8))

        #expect(msg.content == "Simple response")
        #expect(msg.reasoning == nil)
    }

    @Test
    func responseWithEmptyReasoningTreatedAsNil() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": "Response",
                    "reasoning": ""
                },
                "finish_reason": "stop"
            }],
            "usage": {
                "prompt_tokens": 50,
                "completion_tokens": 20
            }
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let msg = try client.parseResponse(Data(json.utf8))

        #expect(msg.reasoning == nil)
    }

    @Test
    func responsePrefersPrimaryReasoningField() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": "Result",
                    "reasoning": "Primary reasoning",
                    "reasoning_content": "Secondary reasoning"
                },
                "finish_reason": "stop"
            }],
            "usage": {
                "prompt_tokens": 50,
                "completion_tokens": 100
            }
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let msg = try client.parseResponse(Data(json.utf8))

        #expect(msg.reasoning?.content == "Primary reasoning")
    }
}

@Suite
struct StreamingChunkParsingTests {
    @Test
    func streamingChunkWithReasoningFieldParsesCorrectly() throws {
        let json = """
        {
            "choices": [{
                "delta": {
                    "content": null,
                    "reasoning": "Let me think..."
                },
                "finish_reason": null
            }]
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let chunk = try client.parseStreamingChunk(Data(json.utf8))
        let deltas = client.extractDeltas(from: chunk)

        #expect(deltas.count == 1)
        #expect(deltas[0] == .reasoning("Let me think..."))
    }

    @Test
    func streamingChunkWithReasoningContentFieldParsesCorrectly() throws {
        let json = """
        {
            "choices": [{
                "delta": {
                    "content": null,
                    "reasoning_content": "Alternative field..."
                },
                "finish_reason": null
            }]
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let chunk = try client.parseStreamingChunk(Data(json.utf8))
        let deltas = client.extractDeltas(from: chunk)

        #expect(deltas.count == 1)
        #expect(deltas[0] == .reasoning("Alternative field..."))
    }

    @Test
    func streamingChunkPrefersPrimaryReasoningField() throws {
        let json = """
        {
            "choices": [{
                "delta": {
                    "reasoning": "Primary",
                    "reasoning_content": "Secondary"
                },
                "finish_reason": null
            }]
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let chunk = try client.parseStreamingChunk(Data(json.utf8))
        let deltas = client.extractDeltas(from: chunk)

        #expect(deltas.count == 1)
        #expect(deltas[0] == .reasoning("Primary"))
    }

    @Test
    func streamingChunkFiltersEmptyReasoning() throws {
        let json = """
        {
            "choices": [{
                "delta": {
                    "reasoning": "",
                    "content": "Hello"
                },
                "finish_reason": null
            }]
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let chunk = try client.parseStreamingChunk(Data(json.utf8))
        let deltas = client.extractDeltas(from: chunk)

        #expect(deltas.count == 1)
        #expect(deltas[0] == .content("Hello"))
    }

    @Test
    func streamingChunkWithInterleavedReasoningAndContent() throws {
        let json = """
        {
            "choices": [{
                "delta": {
                    "reasoning": "Thinking...",
                    "content": "Response"
                },
                "finish_reason": null
            }]
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let chunk = try client.parseStreamingChunk(Data(json.utf8))
        let deltas = client.extractDeltas(from: chunk)

        #expect(deltas.count == 2)
        #expect(deltas[0] == .reasoning("Thinking..."))
        #expect(deltas[1] == .content("Response"))
    }

    @Test
    func streamingChunkWithoutChoicesDecodesCleanly() throws {
        let json = """
        {
            "usage": {
                "prompt_tokens": 100,
                "completion_tokens": 50
            }
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let chunk = try client.parseStreamingChunk(Data(json.utf8))
        let deltas = client.extractDeltas(from: chunk)

        #expect(deltas.isEmpty)
        #expect(chunk.usage?.promptTokens == 100)
        #expect(chunk.usage?.completionTokens == 50)
    }
}

@Suite
struct ResponseValidationTests {
    @Test
    func emptyToolCallIdThrows() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": null,
                    "tool_calls": [{
                        "id": "",
                        "type": "function",
                        "function": {
                            "name": "get_weather",
                            "arguments": "{}"
                        }
                    }]
                },
                "finish_reason": "tool_calls"
            }],
            "usage": { "prompt_tokens": 10, "completion_tokens": 5 }
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        do {
            _ = try client.parseResponse(Data(json.utf8))
            Issue.record("Expected decoding error for empty tool call id")
        } catch let error as AgentError {
            guard case let .llmError(transport) = error,
                  case let .decodingFailed(desc) = transport
            else {
                Issue.record("Expected decodingFailed, got \(error)")
                return
            }
            #expect(desc.contains("empty"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func emptyFunctionNameThrows() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": null,
                    "tool_calls": [{
                        "id": "call_123",
                        "type": "function",
                        "function": {
                            "name": "",
                            "arguments": "{}"
                        }
                    }]
                },
                "finish_reason": "tool_calls"
            }],
            "usage": { "prompt_tokens": 10, "completion_tokens": 5 }
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        do {
            _ = try client.parseResponse(Data(json.utf8))
            Issue.record("Expected decoding error for empty function name")
        } catch let error as AgentError {
            guard case let .llmError(transport) = error,
                  case let .decodingFailed(desc) = transport
            else {
                Issue.record("Expected decodingFailed, got \(error)")
                return
            }
            #expect(desc.contains("empty"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func nullContentInResponseDecodesToEmptyString() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": null
                },
                "finish_reason": "stop"
            }],
            "usage": { "prompt_tokens": 10, "completion_tokens": 5 }
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let msg = try client.parseResponse(Data(json.utf8))
        #expect(msg.content == "")
    }

    @Test
    func missingContentInResponseDecodesToEmptyString() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant"
                },
                "finish_reason": "stop"
            }],
            "usage": { "prompt_tokens": 10, "completion_tokens": 5 }
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let msg = try client.parseResponse(Data(json.utf8))
        #expect(msg.content == "")
    }

    @Test
    func toolCallWithMalformedArgumentsStillDecodes() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": null,
                    "tool_calls": [{
                        "id": "call_123",
                        "type": "function",
                        "function": {
                            "name": "search",
                            "arguments": "not valid json {"
                        }
                    }]
                },
                "finish_reason": "tool_calls"
            }],
            "usage": { "prompt_tokens": 10, "completion_tokens": 5 }
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let msg = try client.parseResponse(Data(json.utf8))
        #expect(msg.toolCalls.count == 1)
        #expect(msg.toolCalls[0].arguments == "not valid json {")
    }

    @Test
    func multipleToolCallsAllValidated() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": null,
                    "tool_calls": [
                        {"id": "call_1", "type": "function", "function": {"name": "a", "arguments": "{}"}},
                        {"id": "", "type": "function", "function": {"name": "b", "arguments": "{}"}}
                    ]
                },
                "finish_reason": "tool_calls"
            }],
            "usage": { "prompt_tokens": 10, "completion_tokens": 5 }
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        do {
            _ = try client.parseResponse(Data(json.utf8))
            Issue.record("Expected decoding error for empty tool call id in second call")
        } catch let error as AgentError {
            guard case .llmError = error else {
                Issue.record("Expected llmError, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Suite
struct ReasoningDetailsResponseTests {
    @Test
    func responseWithReasoningDetailsDecodes() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": "I'll search for that.",
                    "reasoning_details": [
                        {"type": "reasoning.summary", "summary": "Planning search...", "id": "rs_001", "format": "anthropic-claude-v1", "index": 0},
                        {"type": "reasoning.encrypted", "encrypted": "base64blob==", "id": "re_002", "format": "anthropic-claude-v1", "index": 1}
                    ]
                },
                "finish_reason": "stop"
            }],
            "usage": {"prompt_tokens": 50, "completion_tokens": 30}
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let msg = try client.parseResponse(Data(json.utf8))

        #expect(msg.content == "I'll search for that.")
        #expect(msg.reasoningDetails != nil)
        #expect(msg.reasoningDetails?.count == 2)

        guard case let .object(first) = msg.reasoningDetails?[0] else {
            Issue.record("Expected object")
            return
        }
        #expect(first["type"] == .string("reasoning.summary"))
        #expect(first["summary"] == .string("Planning search..."))

        guard case let .object(second) = msg.reasoningDetails?[1] else {
            Issue.record("Expected object")
            return
        }
        #expect(second["type"] == .string("reasoning.encrypted"))
        #expect(second["encrypted"] == .string("base64blob=="))
    }

    @Test
    func responseWithoutReasoningDetailsHasNilField() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": "Simple response"
                },
                "finish_reason": "stop"
            }],
            "usage": {"prompt_tokens": 50, "completion_tokens": 20}
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let msg = try client.parseResponse(Data(json.utf8))
        #expect(msg.reasoningDetails == nil)
    }

    @Test
    func reasoningDetailsPreservesSnakeCaseKeys() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": "Result",
                    "reasoning_details": [
                        {"type": "reasoning.text", "reasoning_type": "chain_of_thought", "inner_data": {"nested_key": "value"}}
                    ]
                },
                "finish_reason": "stop"
            }],
            "usage": {"prompt_tokens": 10, "completion_tokens": 5}
        }
        """
        let client = OpenAIClient(apiKey: "test", model: "test", baseURL: OpenAIClient.openRouterBaseURL)
        let msg = try client.parseResponse(Data(json.utf8))

        guard let details = msg.reasoningDetails, let first = details.first,
              case let .object(obj) = first
        else {
            Issue.record("Expected reasoning_details with object")
            return
        }
        #expect(obj["reasoning_type"] == .string("chain_of_thought"))
        #expect(obj["inner_data"] == .object(["nested_key": .string("value")]))
        #expect(obj["reasoningType"] == nil, "snake_case keys must NOT be mangled to camelCase")
    }
}
