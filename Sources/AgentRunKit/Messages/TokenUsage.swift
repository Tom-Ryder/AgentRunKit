import Foundation

/// Token counts reported for one returned model response.
///
/// For aggregate coverage, see <doc:TokenAccounting>.
public struct TokenUsage: Sendable, Equatable, Codable {
    /// The complete input count, including reported cache reads and writes.
    public let input: Int
    /// Output tokens excluding reasoning when the provider reports a separate breakdown.
    public let output: Int
    /// Separately reported reasoning tokens, or zero when no breakdown is available.
    public let reasoning: Int
    /// The reported cache-read portion of input, or nil when unavailable.
    public let cacheRead: Int?
    /// The reported cache-write portion of input, or nil when unavailable.
    public let cacheWrite: Int?

    public var total: Int {
        saturatingTokenSum(saturatingTokenSum(input, output), reasoning)
    }

    var inputOutputTotal: Int {
        saturatingTokenSum(input, output)
    }

    public init(
        input: Int = 0, output: Int = 0, reasoning: Int = 0,
        cacheRead: Int? = nil, cacheWrite: Int? = nil
    ) {
        precondition(input >= 0, "input must be non-negative")
        precondition(output >= 0, "output must be non-negative")
        precondition(reasoning >= 0, "reasoning must be non-negative")
        if let cacheRead { precondition(cacheRead >= 0, "cacheRead must be non-negative") }
        if let cacheWrite { precondition(cacheWrite >= 0, "cacheWrite must be non-negative") }
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    private enum CodingKeys: String, CodingKey {
        case input, output, reasoning, cacheRead, cacheWrite
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.decodeTokenCount(forKey: .input)
        output = try container.decodeTokenCount(forKey: .output)
        reasoning = try container.decodeTokenCount(forKey: .reasoning)
        cacheRead = try container.decodeTokenCountIfPresent(forKey: .cacheRead)
        cacheWrite = try container.decodeTokenCountIfPresent(forKey: .cacheWrite)
    }
}

extension KeyedDecodingContainer {
    func decodeTokenCount(forKey key: Key) throws -> Int {
        let count: Int
        do {
            count = try decode(Int.self, forKey: key)
        } catch let error as DecodingError {
            throw error
        } catch {
            // Foundation's numeric conversion error loses its key path at the outer JSONDecoder boundary.
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "\(key.stringValue) must be a representable integer",
                underlyingError: error
            ))
        }
        guard count >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self,
                debugDescription: "\(key.stringValue) must be non-negative, got \(count)"
            )
        }
        return count
    }

    func decodeTokenCountIfPresent(forKey key: Key) throws -> Int? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeTokenCount(forKey: key)
    }
}

func saturatingTokenSum(_ lhs: Int, _ rhs: Int) -> Int {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : result
}
