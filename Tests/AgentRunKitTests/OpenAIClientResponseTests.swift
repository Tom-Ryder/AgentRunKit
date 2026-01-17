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
}
