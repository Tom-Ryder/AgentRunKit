import Foundation

/// An opt-in policy for leveling independently-synthesized PCM chunks to a consistent loudness.
///
/// For a guide on audio workflows, see <doc:MultimodalAndAudio>.
public struct TTSLoudnessMatch: Sendable, Equatable, Hashable, Codable {
    /// The loudness anchor the program is matched to.
    public enum Target: Sendable, Equatable, Hashable, Codable {
        case programMedian
        case lufs(Double)
    }

    /// Whether chunks are leveled to the program median or additionally shifted to an absolute loudness.
    public let target: Target
    /// The maximum per-chunk gain correction in decibels.
    public let maxCorrectionDB: Double
    /// The true-peak ceiling in dBTP the assembled program's measured true peak is held under.
    public let truePeakCeilingDBTP: Double

    public init(
        target: Target = .programMedian,
        maxCorrectionDB: Double = 3.0,
        truePeakCeilingDBTP: Double = -1.0
    ) {
        precondition(
            maxCorrectionDB.isFinite && maxCorrectionDB >= 0,
            "maxCorrectionDB must be finite and non-negative"
        )
        precondition(
            truePeakCeilingDBTP.isFinite && truePeakCeilingDBTP <= 0,
            "truePeakCeilingDBTP must be finite and at most 0"
        )
        if case let .lufs(value) = target {
            precondition(value.isFinite && value <= 0, "target LUFS must be finite and at most 0")
        }
        self.target = target
        self.maxCorrectionDB = maxCorrectionDB
        self.truePeakCeilingDBTP = truePeakCeilingDBTP
    }

    private enum CodingKeys: String, CodingKey {
        case target
        case maxCorrectionDB
        case truePeakCeilingDBTP
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let target = try container.decode(Target.self, forKey: .target)
        let maxCorrectionDB = try container.decode(Double.self, forKey: .maxCorrectionDB)
        let truePeakCeilingDBTP = try container.decode(Double.self, forKey: .truePeakCeilingDBTP)
        guard maxCorrectionDB.isFinite, maxCorrectionDB >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .maxCorrectionDB, in: container,
                debugDescription: "maxCorrectionDB must be finite and non-negative"
            )
        }
        guard truePeakCeilingDBTP.isFinite, truePeakCeilingDBTP <= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .truePeakCeilingDBTP, in: container,
                debugDescription: "truePeakCeilingDBTP must be finite and at most 0"
            )
        }
        if case let .lufs(value) = target, !(value.isFinite && value <= 0) {
            throw DecodingError.dataCorruptedError(
                forKey: .target, in: container,
                debugDescription: "target LUFS must be finite and at most 0"
            )
        }
        self.init(target: target, maxCorrectionDB: maxCorrectionDB, truePeakCeilingDBTP: truePeakCeilingDBTP)
    }
}
