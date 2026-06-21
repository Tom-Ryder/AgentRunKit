@testable import AgentRunKit
import Foundation
import Testing

private let sampleRate = 24000

private func tone(freq: Double, amplitude: Double, seconds: Double) -> [Double] {
    let count = Int(seconds * Double(sampleRate))
    return (0 ..< count).map { amplitude * sin(2 * .pi * freq * Double($0) / Double(sampleRate)) }
}

private func loudness(_ samples: [Double]) throws -> Double {
    try #require(TTSLoudnessMeter.integratedLoudness(samples, sampleRate: sampleRate).lufs)
}

struct TTSLoudnessMeterTests {
    @Test
    func sineMatchesFFmpegValidatedLoudness() throws {
        let lufs = try loudness(tone(freq: 1000, amplitude: 0.5, seconds: 8))
        #expect(abs(lufs - -9.0) < 0.2)
    }

    @Test
    func uniformScalingShiftsLoudnessByExactlyTheDecibels() throws {
        let base = tone(freq: 1000, amplitude: 0.5, seconds: 8)
        let loud = try loudness(base)
        let quiet = try loudness(base.map { $0 * 0.5 })
        #expect(abs((loud - quiet) - 6.0206) < 0.05)
    }

    @Test
    func appendedSilenceIsGatedOutAndDoesNotChangeLoudness() throws {
        let speech = tone(freq: 1000, amplitude: 0.5, seconds: 4)
        let bare = try loudness(speech)
        let withSilence = try loudness(speech + [Double](repeating: 0, count: sampleRate * 4))
        #expect(abs(bare - withSilence) < 0.3)
    }

    @Test
    func bufferShorterThanAGatingBlockIsUnmeasurable() {
        let short = tone(freq: 1000, amplitude: 0.5, seconds: 0.2)
        let reading = TTSLoudnessMeter.integratedLoudness(short, sampleRate: sampleRate)
        #expect(reading == .unmeasurable(.shorterThanGatingBlock))
    }

    @Test
    func silenceIsUnmeasurableBelowTheAbsoluteGate() {
        let silence = [Double](repeating: 0, count: sampleRate * 2)
        let reading = TTSLoudnessMeter.integratedLoudness(silence, sampleRate: sampleRate)
        #expect(reading == .unmeasurable(.belowAbsoluteGate))
    }

    @Test
    func relativeGateExcludesQuietBlocksWellAboveTheAbsoluteGate() throws {
        let loud = tone(freq: 1000, amplitude: 0.5, seconds: 4)
        let quiet = tone(freq: 1000, amplitude: 0.05, seconds: 4)
        let loudOnly = try loudness(loud)
        let mixed = try loudness(loud + quiet)
        #expect(abs(mixed - loudOnly) < 1.0)
    }

    @Test
    func truePeakRecoversInterSamplePeakAboveSamplePeak() throws {
        let offPhase = (0 ..< sampleRate * 2).map { sin(2 * .pi * 6000 * Double($0) / Double(sampleRate) + .pi / 4) }
        let samplePeak = try 20 * log10(#require(offPhase.map(abs).max()))
        let truePeak = TTSLoudnessMeter.truePeakDBTP(offPhase)
        #expect(samplePeak < -2.5)
        #expect(truePeak > samplePeak + 2.0)
        #expect(truePeak > -0.5)
    }

    @Test
    func truePeakOfALowLevelToneStaysNearItsSamplePeak() throws {
        let quiet = tone(freq: 1000, amplitude: 0.25, seconds: 1)
        let samplePeak = try 20 * log10(#require(quiet.map(abs).max()))
        let truePeak = TTSLoudnessMeter.truePeakDBTP(quiet)
        #expect(abs(truePeak - samplePeak) < 0.5)
    }

    @Test
    func truePeakOfSilenceIsNegativeInfinity() {
        #expect(TTSLoudnessMeter.truePeakDBTP([Double](repeating: 0, count: 100)) == -.infinity)
    }
}
