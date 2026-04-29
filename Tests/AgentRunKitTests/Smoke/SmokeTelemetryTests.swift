@testable import AgentRunKit
import Foundation
import Testing

struct SmokeTelemetryTests {
    @Test func classifierRecognizesAssertionFailure() {
        let classification = classifySmokeFailure(
            SmokeAssertionFailure(fileID: "Tests/Foo.swift", line: 12, message: "Expected success")
        )

        #expect(classification.kind == .assertionFailure)
        #expect(classification.bodyExcerpt?.contains("Expected success") == true)
    }

    @Test func classifierRecognizesHTTPError() {
        let classification = classifySmokeFailure(
            AgentError.llmError(.httpError(statusCode: 400, body: "invalid_request_error"))
        )

        #expect(classification.kind == .httpError)
        #expect(classification.httpStatus == 400)
        #expect(classification.bodyExcerpt?.contains("invalid_request_error") == true)
    }

    @Test func classifierUnwrapsTTSChunkTransportFailure() {
        let classification = classifySmokeFailure(
            TTSError.chunkFailed(
                index: 0,
                total: 1,
                sourceRange: 0 ..< 4,
                .rateLimited(retryAfter: .seconds(3))
            )
        )

        #expect(classification.kind == .rateLimited)
        #expect(classification.httpStatus == 429)
    }

    @Test func classifierPreservesStreamFailureTaxonomy() {
        let cases: [(TransportError, SmokeFailureKind)] = [
            (.streamFailed(.idleTimeout(diagnostics: .empty)), .idleTimeout),
            (.streamFailed(.providerTerminationMissing(diagnostics: .empty)), .providerTerminationMissing),
            (.streamFailed(.finishedDeltaMissing(diagnostics: .empty)), .finishedDeltaMissing),
            (
                .streamFailed(.midStreamTransportFailure(code: .timedOut, diagnostics: .empty)),
                .midStreamTransportFailure
            ),
            (
                .streamFailed(.providerError(provider: .anthropic, code: nil, message: "overloaded")),
                .providerError
            ),
            (
                .streamFailed(.malformedStream(
                    reason: .finalizedSemanticStateDiverged,
                    diagnostics: .empty
                )),
                .malformedStream
            ),
        ]

        for (error, expectedKind) in cases {
            let classification = classifySmokeFailure(AgentError.llmError(error))
            #expect(classification.kind == expectedKind)
        }

        let providerError = classifySmokeFailure(AgentError.llmError(.streamFailed(.providerError(
            provider: .anthropic,
            code: "overloaded_error",
            message: "overloaded"
        ))))
        #expect(providerError.bodyExcerpt?.contains("overloaded") == true)

        let malformed = classifySmokeFailure(AgentError.llmError(.streamFailed(.malformedStream(
            reason: .finalizedSemanticStateDiverged,
            diagnostics: .empty
        ))))
        #expect(malformed.bodyExcerpt?.contains("Finalized semantic state") == true)
    }

    @Test func classifierCapturesStructuredOutputRawText() {
        let classification = classifySmokeFailure(
            SmokeStructuredOutputFailure(
                rawContent: "partial { exercises: [",
                underlyingDescription: "malformed JSON"
            )
        )

        #expect(classification.kind == .structuredOutputDecodingFailed)
        #expect(classification.assistantTextExcerpt?.contains("partial") == true)
    }

    @Test func jsonlWritesParseableLine() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoke-\(UUID().uuidString).jsonl").path
        defer {
            try? FileManager.default.removeItem(atPath: path)
        }

        try appendSmokeJSONL(
            SmokeTelemetryRecord(
                suite: "suite",
                test: "test",
                provider: "provider",
                model: "model",
                durationMillis: 12,
                kind: .httpError,
                httpStatus: 500,
                bodyExcerpt: "body",
                assistantTextExcerpt: nil
            ),
            to: path
        )

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let contents = try #require(String(data: data, encoding: .utf8))
        let lines = contents.split(separator: "\n")

        #expect(lines.count == 1)

        let decoded = try JSONDecoder().decode(SmokeTelemetryRecord.self, from: Data(lines[0].utf8))
        #expect(decoded.suite == "suite")
        #expect(decoded.kind == .httpError)
        #expect(decoded.httpStatus == 500)
    }
}
