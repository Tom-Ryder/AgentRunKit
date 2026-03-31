@testable import AgentRunKit
import Testing

struct TransportErrorTests {
    @Test
    func errorsAreEquatable() {
        #expect(TransportError.invalidResponse == TransportError.invalidResponse)
        #expect(TransportError.noChoices == TransportError.noChoices)
        #expect(TransportError.streamStalled == TransportError.streamStalled)
        #expect(TransportError.streamStalled != TransportError.invalidResponse)
        let err400 = TransportError.httpError(statusCode: 400, body: "bad")
        let err401 = TransportError.httpError(statusCode: 401, body: "bad")
        #expect(err400 == err400)
        #expect(err400 != err401)
    }

    @Test
    func promptTooLongClassificationMatchesProviderOverflowBodies() {
        let providerErrors: [TransportError] = [
            .httpError(
                statusCode: 400,
                body: #"""
                {
                    "error": {
                        "message": "This model's maximum context length is 128000 tokens.",
                        "code": "context_length_exceeded"
                    }
                }
                """#
            ),
            .httpError(
                statusCode: 400,
                body: #"""
                {
                    "type": "error",
                    "error": {
                        "type": "invalid_request_error",
                        "message": "prompt is too long: 200001 tokens > 200000 maximum"
                    }
                }
                """#
            ),
            .httpError(
                statusCode: 400,
                body: #"""
                {
                    "error": {
                        "code": 400,
                        "message":
                            "The input token count (307201) exceeds the maximum number of tokens allowed (307200).",
                        "status": "INVALID_ARGUMENT"
                    }
                }
                """#
            ),
            .httpError(
                statusCode: 400,
                body: #"""
                {
                    "error": {
                        "code": 400,
                        "message": "prompt is too long: 200001 tokens > 200000 maximum",
                        "status": "INVALID_ARGUMENT"
                    }
                }
                """#
            ),
            .httpError(
                statusCode: 400,
                body: #"""
                {
                    "error": {
                        "code": 400,
                        "message":
                            "The input token count (8193) exceeds the maximum number of tokens allowed (8192).",
                        "status": "INVALID_ARGUMENT"
                    }
                }
                """#
            ),
        ]

        for error in providerErrors {
            #expect(error.isPromptTooLong)
        }
    }

    @Test
    func promptTooLongClassificationNormalizesWhitespace() {
        let providerErrors: [TransportError] = [
            .other(
                """
                invalid_request_error:
                    prompt
                    is   too\tlong: 200001 tokens > 200000 maximum
                """
            ),
            .other(
                """
                INVALID_ARGUMENT:
                    The input token count
                    (307201)\t exceeds the maximum number of tokens allowed
                    (307200).
                """
            ),
        ]

        for error in providerErrors {
            #expect(error.isPromptTooLong)
        }
    }

    @Test
    func promptTooLongClassificationMatchesOtherOverflowMessages() {
        let providerErrors: [TransportError] = [
            .other(
                "context_length_exceeded: This model's maximum context length is 128000 tokens."
            ),
            .other(
                "invalid_request_error: prompt is too long: 200001 tokens > 200000 maximum"
            ),
            .other(
                """
                INVALID_ARGUMENT: The input token count (307201) exceeds the maximum number of \
                tokens allowed (307200).
                """
            ),
        ]

        for error in providerErrors {
            #expect(error.isPromptTooLong)
        }
    }

    @Test
    func promptTooLongClassificationRejectsGenericRequestFailures() {
        let nonOverflowErrors: [TransportError] = [
            .httpError(
                statusCode: 400,
                body: """
                {
                    "error": {
                        "message": "prompt is too long for the audit annotation",
                        "type": "invalid_request_error"
                    }
                }
                """
            ),
            .httpError(
                statusCode: 400,
                body: """
                {"error":{"message":"Invalid value for temperature","code":"invalid_request_error"}}
                """
            ),
            .httpError(
                statusCode: 413,
                body: """
                {"error":{"message":"Request body too large"}}
                """
            ),
            .httpError(
                statusCode: 413,
                body: """
                {
                    "error": {
                        "message": "prompt is too long: 200001 tokens > 200000 maximum",
                        "code": "context_length_exceeded"
                    }
                }
                """
            ),
            .other(
                "INVALID_ARGUMENT: The maximum output tokens must be greater than zero."
            ),
            .other(
                "invalid_request_error: prompt is too long for this screenshot caption."
            ),
            .other(
                "Reviewer note: prompt is too long for this screenshot caption, shorten it."
            ),
            .other("Request too long for audit logging."),
        ]

        for error in nonOverflowErrors {
            #expect(!error.isPromptTooLong)
        }
    }
}
