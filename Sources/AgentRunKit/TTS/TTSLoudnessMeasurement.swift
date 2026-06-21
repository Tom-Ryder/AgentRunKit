import Foundation

/// The loudness measured for one segment and the gain that loudness matching applied to it.
public struct TTSLoudnessMeasurement: Sendable, Equatable, Hashable, Codable {
    /// The segment's gated integrated loudness before correction, or nil when it was too short or too quiet to measure.
    public let integratedLUFS: Double?
    public let appliedGainDB: Double

    public init(integratedLUFS: Double?, appliedGainDB: Double) {
        self.integratedLUFS = integratedLUFS
        self.appliedGainDB = appliedGainDB
    }
}

/// The whole-program loudness outcome of a loudness-matched ``TTSConcatenationResult``.
public struct TTSLoudnessSummary: Sendable, Equatable, Hashable, Codable {
    /// The assembled program's gated integrated loudness after correction, or nil when it has no measurable signal.
    public let achievedLUFS: Double?
    /// The absolute target requested, or nil when matching only to the program median.
    public let requestedTargetLUFS: Double?
    /// The uniform attenuation in decibels the true-peak guard applied to hold the program under its ceiling.
    public let appliedTrimDB: Double
    /// The assembled program's true peak in dBTP, or nil when it has no signal.
    public let truePeakDBTP: Double?

    public init(achievedLUFS: Double?, requestedTargetLUFS: Double?, appliedTrimDB: Double, truePeakDBTP: Double?) {
        self.achievedLUFS = achievedLUFS
        self.requestedTargetLUFS = requestedTargetLUFS
        self.appliedTrimDB = appliedTrimDB
        self.truePeakDBTP = truePeakDBTP
    }
}
