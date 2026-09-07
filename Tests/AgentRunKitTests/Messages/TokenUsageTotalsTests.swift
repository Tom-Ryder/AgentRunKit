import AgentRunKit
import Foundation
import Testing

struct TokenUsageTotalsTests {
    @Test
    func emptyTotalsDistinguishNoResponsesFromMissingUsage() {
        let empty = TokenUsageTotals()
        #expect(empty.input == 0)
        #expect(empty.output == 0)
        #expect(empty.reasoning == 0)
        #expect(empty.total == 0)
        #expect(empty.cacheRead == 0)
        #expect(empty.cacheWrite == 0)
        #expect(empty.coverage == .complete)
        #expect(empty.cacheReadCoverage == .complete)
        #expect(empty.cacheWriteCoverage == .complete)

        var missing = empty
        missing.record(nil)
        #expect(missing.input == 0)
        #expect(missing.output == 0)
        #expect(missing.reasoning == 0)
        #expect(missing.total == 0)
        #expect(missing.cacheRead == nil)
        #expect(missing.cacheWrite == nil)
        #expect(missing.coverage == .unavailable)
        #expect(missing.cacheReadCoverage == .unavailable)
        #expect(missing.cacheWriteCoverage == .unavailable)
        #expect(missing != empty)
        missing.record(nil)
        #expect(missing.coverage == .unavailable)
        #expect(missing.cacheReadCoverage == .unavailable)
        #expect(missing.cacheWriteCoverage == .unavailable)
        #expect(missing.total == 0)
    }

    @Test
    func measuredZeroIsAvailableWithoutInferringCacheMeasurements() {
        var totals = TokenUsageTotals()
        totals.record(TokenUsage())
        #expect(totals.coverage == .complete)
        #expect(totals.total == 0)
        #expect(totals.cacheRead == nil)
        #expect(totals.cacheWrite == nil)
        #expect(totals.cacheReadCoverage == .unavailable)
        #expect(totals.cacheWriteCoverage == .unavailable)
        totals.record(TokenUsage(cacheRead: 0, cacheWrite: 0))
        #expect(totals.coverage == .complete)
        #expect(totals.total == 0)
        #expect(totals.cacheRead == 0)
        #expect(totals.cacheWrite == 0)
        #expect(totals.cacheReadCoverage == .partial)
        #expect(totals.cacheWriteCoverage == .partial)
    }

    @Test
    func repeatedMeasurementsSumEachDimensionWithoutAddingCachesToTotal() {
        var totals = TokenUsageTotals()
        totals.record(TokenUsage(input: 100, output: 20, reasoning: 7, cacheRead: 60, cacheWrite: 30))
        totals.record(TokenUsage(input: 200, output: 40, reasoning: 9, cacheRead: 0, cacheWrite: 5))
        #expect(totals.input == 300)
        #expect(totals.output == 60)
        #expect(totals.reasoning == 16)
        #expect(totals.total == 376)
        #expect(totals.cacheRead == 60)
        #expect(totals.cacheWrite == 35)
        #expect(totals.coverage == .complete)
        #expect(totals.cacheReadCoverage == .complete)
        #expect(totals.cacheWriteCoverage == .complete)
    }

    @Test(arguments: [0, 1, 2])
    func missingUsageMakesCoveragePartialRegardlessOfPosition(_ missingIndex: Int) {
        var samples: [TokenUsage?] = [
            TokenUsage(input: 100, output: 20, reasoning: 7, cacheRead: 0, cacheWrite: 30),
            TokenUsage(input: 200, output: 40, reasoning: 9, cacheRead: 60, cacheWrite: 5)
        ]
        samples.insert(nil, at: missingIndex)
        var totals = TokenUsageTotals()
        for sample in samples {
            totals.record(sample)
        }
        #expect(totals.input == 300)
        #expect(totals.output == 60)
        #expect(totals.reasoning == 16)
        #expect(totals.total == 376)
        #expect(totals.cacheRead == 60)
        #expect(totals.cacheWrite == 35)
        #expect(totals.coverage == .partial)
        #expect(totals.cacheReadCoverage == .partial)
        #expect(totals.cacheWriteCoverage == .partial)
        totals.record(nil)
        #expect(totals.coverage == .partial)
        #expect(totals.cacheReadCoverage == .partial)
        #expect(totals.cacheWriteCoverage == .partial)
        #expect(totals.total == 376)
    }

    @Test
    func cacheDimensionsTrackAvailabilityIndependently() {
        var totals = TokenUsageTotals()
        totals.record(TokenUsage(input: 100, cacheRead: 0))
        #expect(totals.cacheRead == 0)
        #expect(totals.cacheReadCoverage == .complete)
        #expect(totals.cacheWrite == nil)
        #expect(totals.cacheWriteCoverage == .unavailable)
        totals.record(TokenUsage(input: 200, cacheRead: 50, cacheWrite: 25))
        #expect(totals.cacheRead == 50)
        #expect(totals.cacheReadCoverage == .complete)
        #expect(totals.cacheWrite == 25)
        #expect(totals.cacheWriteCoverage == .partial)
        totals.record(TokenUsage(input: 300, cacheWrite: 0))
        #expect(totals.input == 600)
        #expect(totals.coverage == .complete)
        #expect(totals.cacheRead == 50)
        #expect(totals.cacheReadCoverage == .partial)
        #expect(totals.cacheWrite == 25)
        #expect(totals.cacheWriteCoverage == .partial)
    }

    @Test
    func saturationPreservesCoverageAndOptionalCounts() {
        var totals = TokenUsageTotals()
        totals.record(TokenUsage(
            input: .max - 1, output: .max - 2, reasoning: .max - 3,
            cacheRead: .max - 4, cacheWrite: .max - 5
        ))
        #expect(totals.total == .max)
        totals.record(TokenUsage(input: 10, output: 10, reasoning: 10, cacheRead: 10, cacheWrite: 10))
        #expect(totals.input == .max)
        #expect(totals.output == .max)
        #expect(totals.reasoning == .max)
        #expect(totals.total == .max)
        #expect(totals.cacheRead == .max)
        #expect(totals.cacheWrite == .max)
        #expect(totals.coverage == .complete)
        #expect(totals.cacheReadCoverage == .complete)
        #expect(totals.cacheWriteCoverage == .complete)
        totals.record(nil)
        #expect(totals.total == .max)
        #expect(totals.cacheRead == .max)
        #expect(totals.cacheWrite == .max)
        #expect(totals.coverage == .partial)
    }
}

struct TokenUsageTotalsCodableTests {
    @Test
    func emptyEncodingPinsAllZeroCountsAndMetadata() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(TokenUsageTotals())
        let expected = """
        {"accounting":{"type":"empty"},"cacheRead":0,"cacheWrite":0,"input":0,"output":0,"reasoning":0}
        """
        #expect(encoded == Data(expected.utf8))
        #expect(try JSONDecoder().decode(TokenUsageTotals.self, from: encoded) == TokenUsageTotals())
    }

    @Test
    func observedEncodingPreservesPartialCoverageAndUnavailableCacheOmission() throws {
        var totals = TokenUsageTotals()
        totals.record(TokenUsage(input: 100, output: 20, reasoning: 7, cacheRead: 0))
        totals.record(nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(totals)
        let expected = """
        {"accounting":{"cacheRead":"partial","cacheWrite":"unavailable","type":"observed","usage":"partial"},\
        "cacheRead":0,"input":100,"output":20,"reasoning":7}
        """
        #expect(encoded == Data(expected.utf8))
        var decoded = try JSONDecoder().decode(TokenUsageTotals.self, from: encoded)
        #expect(decoded == totals)
        decoded.record(TokenUsage(input: 25, output: 10, cacheRead: 5, cacheWrite: 0))
        #expect(decoded.input == 125)
        #expect(decoded.output == 30)
        #expect(decoded.reasoning == 7)
        #expect(decoded.cacheRead == 5)
        #expect(decoded.cacheWrite == 0)
        #expect(decoded.coverage == .partial)
        #expect(decoded.cacheReadCoverage == .partial)
        #expect(decoded.cacheWriteCoverage == .partial)
    }

    @Test(arguments: [
        (#"{"input":0,"output":0,"reasoning":0,"cacheRead":0,"cacheWrite":0}"#, 0, 0, 0, 0, 0),
        (#"{"input":100,"output":20,"reasoning":7,"cacheRead":600,"cacheWrite":200}"#, 100, 20, 7, 600, 200)
    ])
    func legacyValuesRetainUncertaintyAcrossRecordingAndRoundTrip(
        _ json: String, input: Int, output: Int, reasoning: Int, cacheRead: Int, cacheWrite: Int
    ) throws {
        var totals = try JSONDecoder().decode(TokenUsageTotals.self, from: Data(json.utf8))
        #expect(totals.input == input)
        #expect(totals.output == output)
        #expect(totals.reasoning == reasoning)
        #expect(totals.cacheRead == cacheRead)
        #expect(totals.cacheWrite == cacheWrite)
        #expect(totals != TokenUsageTotals())
        #expect(totals.coverage == .partial)
        #expect(totals.cacheReadCoverage == .partial)
        #expect(totals.cacheWriteCoverage == .partial)
        totals.record(TokenUsage(input: 50, output: 5, reasoning: 3, cacheRead: 10, cacheWrite: 20))
        #expect(totals.input == input + 50)
        #expect(totals.output == output + 5)
        #expect(totals.reasoning == reasoning + 3)
        #expect(totals.cacheRead == cacheRead + 10)
        #expect(totals.cacheWrite == cacheWrite + 20)
        #expect(totals.coverage == .partial)
        #expect(totals.cacheReadCoverage == .partial)
        #expect(totals.cacheWriteCoverage == .partial)
        let encoded = try JSONEncoder().encode(totals)
        #expect(try JSONDecoder().decode(TokenUsageTotals.self, from: encoded) == totals)
    }

    @Test(arguments: [
        #"{"input":0,"output":0,"reasoning":0}"#,
        #"{"input":0,"output":0,"reasoning":0,"cacheRead":null,"cacheWrite":null}"#
    ])
    func legacyZerosWithoutCacheCountsAreObservedPartial(_ json: String) throws {
        var totals = try JSONDecoder().decode(TokenUsageTotals.self, from: Data(json.utf8))
        #expect(totals.total == 0)
        #expect(totals.coverage == .partial)
        #expect(totals.cacheRead == nil)
        #expect(totals.cacheWrite == nil)
        #expect(totals.cacheReadCoverage == .unavailable)
        #expect(totals.cacheWriteCoverage == .unavailable)
        totals.record(TokenUsage(cacheRead: 0))
        #expect(totals.coverage == .partial)
        #expect(totals.cacheRead == 0)
        #expect(totals.cacheReadCoverage == .partial)
        #expect(totals.cacheWriteCoverage == .unavailable)
    }

    @Test(arguments: [
        (
            #"{"type":"observed","usage":"unavailable","cacheRead":"unavailable","cacheWrite":"unavailable"}"#,
            TokenUsageCoverage.unavailable
        ),
        (
            #"{"type":"observed","usage":"complete","cacheRead":"unavailable","cacheWrite":"unavailable"}"#,
            TokenUsageCoverage.complete
        )
    ])
    func observedZeroCountsPreserveTheirCoverage(_ metadata: String, coverage: TokenUsageCoverage) throws {
        let json = #"{"input":0,"output":0,"reasoning":0,"accounting":\#(metadata)}"#
        let totals = try JSONDecoder().decode(TokenUsageTotals.self, from: Data(json.utf8))
        #expect(totals != TokenUsageTotals())
        #expect(totals.total == 0)
        #expect(totals.coverage == coverage)
        #expect(totals.cacheRead == nil)
        #expect(totals.cacheWrite == nil)
        #expect(totals.cacheReadCoverage == .unavailable)
        #expect(totals.cacheWriteCoverage == .unavailable)
        let encoded = try JSONEncoder().encode(totals)
        #expect(try JSONDecoder().decode(TokenUsageTotals.self, from: encoded) == totals)
    }

    @Test
    func zeroMeasurementsRemainObservedAcrossPersistence() throws {
        var totals = TokenUsageTotals()
        totals.record(TokenUsage(cacheRead: 0, cacheWrite: 0))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(totals)
        let expected = """
        {"accounting":{"cacheRead":"complete","cacheWrite":"complete","type":"observed","usage":"complete"},\
        "cacheRead":0,"cacheWrite":0,"input":0,"output":0,"reasoning":0}
        """
        #expect(encoded == Data(expected.utf8))
        var decoded = try JSONDecoder().decode(TokenUsageTotals.self, from: encoded)
        #expect(decoded != TokenUsageTotals())
        #expect(decoded == totals)
        decoded.record(nil)
        #expect(decoded.total == 0)
        #expect(decoded.cacheRead == 0)
        #expect(decoded.cacheWrite == 0)
        #expect(decoded.coverage == .partial)
        #expect(decoded.cacheReadCoverage == .partial)
        #expect(decoded.cacheWriteCoverage == .partial)
    }
}

struct TokenUsageTotalsValidationTests {
    @Test
    func unavailableUsageRejectsPartialCacheWriteCoverage() throws {
        let json = """
        {"input":0,"output":0,"reasoning":0,"cacheWrite":0,"accounting":\
        {"type":"observed","usage":"unavailable","cacheRead":"unavailable","cacheWrite":"partial"}}
        """
        do {
            _ = try JSONDecoder().decode(TokenUsageTotals.self, from: Data(json.utf8))
            Issue.record("Expected unavailable usage to reject partial cache-write coverage")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.codingPath.map(\.stringValue) == ["accounting"])
        }
    }

    @Test(arguments: [
        "null", "[]", "0", "{}", #"{"type":"unknown"}"#,
        #"{"type":"observed"}"#,
        #"{"type":"observed","usage":"complete","cacheRead":"complete"}"#,
        #"{"type":"observed","usage":"complete","cacheWrite":"complete"}"#,
        #"{"type":"observed","cacheRead":"complete","cacheWrite":"complete"}"#,
        #"{"type":"observed","usage":"invalid","cacheRead":"complete","cacheWrite":"complete"}"#,
        #"{"type":"observed","usage":"complete","cacheRead":null,"cacheWrite":"complete"}"#,
        #"{"type":"observed","usage":"complete","cacheRead":"complete","cacheWrite":0}"#
    ])
    func malformedPresentAccountingNeverUsesLegacyDecoding(_ metadata: String) throws {
        let json = """
        {"input":0,"output":0,"reasoning":0,"cacheRead":0,"cacheWrite":0,"accounting":\(metadata)}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TokenUsageTotals.self, from: Data(json.utf8))
        }
    }

    @Test(arguments: [
        #"{"input":1,"output":0,"reasoning":0,"cacheRead":0,"cacheWrite":0,"accounting":{"type":"empty"}}"#,
        #"{"input":0,"output":1,"reasoning":0,"cacheRead":0,"cacheWrite":0,"accounting":{"type":"empty"}}"#,
        #"{"input":0,"output":0,"reasoning":1,"cacheRead":0,"cacheWrite":0,"accounting":{"type":"empty"}}"#,
        #"{"input":0,"output":0,"reasoning":0,"cacheRead":1,"cacheWrite":0,"accounting":{"type":"empty"}}"#,
        #"{"input":0,"output":0,"reasoning":0,"cacheRead":0,"cacheWrite":1,"accounting":{"type":"empty"}}"#,
        #"{"input":0,"output":0,"reasoning":0,"cacheRead":0,"accounting":{"type":"empty"}}"#,
        #"{"input":0,"output":0,"reasoning":0,"cacheRead":null,"cacheWrite":0,"accounting":{"type":"empty"}}"#,
        """
        {"input":1,"output":0,"reasoning":0,"accounting":\
        {"type":"observed","usage":"unavailable","cacheRead":"unavailable","cacheWrite":"unavailable"}}
        """,
        """
        {"input":0,"output":1,"reasoning":0,"accounting":\
        {"type":"observed","usage":"unavailable","cacheRead":"unavailable","cacheWrite":"unavailable"}}
        """,
        """
        {"input":0,"output":0,"reasoning":1,"accounting":\
        {"type":"observed","usage":"unavailable","cacheRead":"unavailable","cacheWrite":"unavailable"}}
        """,
        """
        {"input":0,"output":0,"reasoning":0,"cacheRead":0,"accounting":\
        {"type":"observed","usage":"unavailable","cacheRead":"partial","cacheWrite":"unavailable"}}
        """,
        """
        {"input":1,"output":0,"reasoning":0,"cacheRead":0,"accounting":\
        {"type":"observed","usage":"partial","cacheRead":"complete","cacheWrite":"unavailable"}}
        """,
        """
        {"input":1,"output":0,"reasoning":0,"cacheWrite":0,"accounting":\
        {"type":"observed","usage":"partial","cacheRead":"unavailable","cacheWrite":"complete"}}
        """,
        """
        {"input":1,"output":0,"reasoning":0,"accounting":\
        {"type":"observed","usage":"complete","cacheRead":"complete","cacheWrite":"unavailable"}}
        """,
        """
        {"input":1,"output":0,"reasoning":0,"accounting":\
        {"type":"observed","usage":"partial","cacheRead":"unavailable","cacheWrite":"partial"}}
        """,
        """
        {"input":1,"output":0,"reasoning":0,"cacheRead":0,"cacheWrite":0,"accounting":\
        {"type":"observed","usage":"complete","cacheRead":"unavailable","cacheWrite":"unavailable"}}
        """
    ])
    func contradictoryValuesAndCoverageFailDecoding(_ json: String) throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TokenUsageTotals.self, from: Data(json.utf8))
        }
    }

    @Test(arguments: [
        #"{"output":0,"reasoning":0}"#,
        #"{"input":0,"reasoning":0}"#,
        #"{"input":0,"output":0}"#,
        #"{"input":-1,"output":0,"reasoning":0}"#,
        #"{"input":0,"output":-1,"reasoning":0}"#,
        #"{"input":0,"output":0,"reasoning":-1}"#,
        #"{"input":0,"output":0,"reasoning":0,"cacheRead":-1}"#,
        #"{"input":0,"output":0,"reasoning":0,"cacheWrite":-1}"#,
        #"{"input":"0","output":0,"reasoning":0}"#,
        #"{"input":0,"output":null,"reasoning":0}"#,
        #"{"input":0,"output":0,"reasoning":0.5}"#,
        #"{"input":9223372036854775808,"output":0,"reasoning":0}"#,
        #"{"input":0,"output":0,"reasoning":0,"cacheRead":9223372036854775808}"#
    ])
    func malformedCountsFailDecoding(_ json: String) throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TokenUsageTotals.self, from: Data(json.utf8))
        }
    }
}
