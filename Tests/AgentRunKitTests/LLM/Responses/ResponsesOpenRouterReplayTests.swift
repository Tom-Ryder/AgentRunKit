@testable import AgentRunKit
import Foundation
import Testing

struct ResponsesOpenRouterReplayTests {
    @Test
    func openRouterFactoryTargetsStatelessEncryptedReasoning() async throws {
        let client = ResponsesAPIClient.openRouter(apiKey: "sk-or-test", model: "x-ai/grok-4")
        let request = try await client.buildRequest(messages: [.user("Hi")], tools: [])
        let urlRequest = try await client.buildURLRequest(request)
        #expect(urlRequest.url?.absoluteString == "https://openrouter.ai/api/v1/responses")

        let json = try encodeRequest(request)
        #expect(json["store"] as? Bool == false)
        #expect(json["include"] as? [String] == ["reasoning.encrypted_content"])
    }

    @Test
    func encryptedContentReasoningSurvivesContinuityReplay() async throws {
        let blob = "gAAAAABencrypted-reasoning-payload-1234567890=="
        let json = """
        {
            "id": "resp_enc",
            "status": "completed",
            "output": [
                {
                    "type": "reasoning",
                    "id": "rs_enc_001",
                    "summary": [],
                    "encrypted_content": "\(blob)"
                },
                {
                    "type": "message",
                    "id": "msg_enc_001",
                    "status": "completed",
                    "role": "assistant",
                    "content": [{"type": "output_text", "text": "The answer is 42."}]
                }
            ],
            "usage": {"input_tokens": 10, "output_tokens": 5}
        }
        """
        let client = ResponsesAPIClient.openRouter(apiKey: "sk-or-test", model: "x-ai/grok-4")
        let response = try await client.decodeResponse(Data(json.utf8))
        let message = await client.parseResponse(response)

        guard case let .object(payload) = message.continuity?.payload,
              case let .array(output) = payload["output"],
              case let .object(reasoning) = output.first
        else {
            Issue.record("Expected Responses continuity with a reasoning output item")
            return
        }
        #expect(reasoning["encrypted_content"] == .string(blob))

        let request = try await client.buildRequest(messages: [.assistant(message)], tools: [])
        let encoded = try encodeRequest(request)
        let input = try #require(encoded["input"] as? [[String: Any]])
        #expect(input[0]["type"] as? String == "reasoning")
        #expect(input[0]["id"] as? String == "rs_enc_001")
        #expect(input[0]["encrypted_content"] as? String == blob)
        #expect(input[1]["type"] as? String == "message")
        #expect(input[1]["id"] as? String == "msg_enc_001")
    }
}
