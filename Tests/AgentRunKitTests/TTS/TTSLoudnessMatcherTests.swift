@testable import AgentRunKit
import Foundation
import Testing

private let pcmFormat: PCMFormat = {
    guard let format = PCMFormat(TTSAudioEncoding(.pcm, sampleRate: 24000, channels: 1, bitsPerSample: 16)) else {
        preconditionFailure("test fixture encoding must be valid 16-bit PCM")
    }
    return format
}()

private func pcmTone(amplitude: Double, seconds: Double, freq: Double = 1000) -> Data {
    let count = Int(seconds * 24000)
    var data = Data(capacity: count * 2)
    for index in 0 ..< count {
        let sample = amplitude * sin(2 * .pi * freq * Double(index) / 24000)
        let bits = UInt16(bitPattern: Int16((max(-1.0, min(1.0, sample)) * 32767.0).rounded()))
        data.append(UInt8(bits & 0x00FF))
        data.append(UInt8(bits >> 8))
    }
    return data
}

private func boundaries(_ count: Int) -> [TTSBoundary] {
    (0 ..< count).map { $0 == count - 1 ? .end : .sentence }
}

private func match(
    _ segments: [Data],
    _ loudness: TTSLoudnessMatch,
    boundaries seams: [TTSBoundary]? = nil,
    policy: TTSStitchPolicy = TTSStitchPolicy()
) throws -> TTSLoudnessMatcher.Output {
    try TTSLoudnessMatcher.match(
        segments: segments,
        boundaries: seams ?? boundaries(segments.count),
        policy: policy,
        loudness: loudness,
        format: pcmFormat
    )
}

private func spread(_ values: [Double]) throws -> Double {
    try #require(values.max()) - (try #require(values.min()))
}

private func decodePCM(_ data: Data) -> [Double] {
    let bytes = [UInt8](data)
    return stride(from: 0, to: bytes.count, by: 2).map { index in
        Double(Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))) / 32768.0
    }
}

struct TTSLoudnessMatcherTests {
    @Test
    func levelingReducesSpreadAndRespectsTheClamp() throws {
        let segments = [
            pcmTone(amplitude: 0.5, seconds: 1),
            pcmTone(amplitude: 0.25, seconds: 1),
            pcmTone(amplitude: 0.4, seconds: 1),
            pcmTone(amplitude: 0.15, seconds: 1),
        ]
        let output = try match(segments, TTSLoudnessMatch(maxCorrectionDB: 6))
        let measured = output.measurements.compactMap(\.integratedLUFS)
        #expect(measured.count == 4)
        let corrected = try output.measurements.map { try #require($0.integratedLUFS) + $0.appliedGainDB }
        #expect(try spread(corrected) < spread(measured))
        for measurement in output.measurements {
            #expect(abs(measurement.appliedGainDB) <= 6.0 + 1e-9)
        }
    }

    @Test
    func singleChunkAppliesNoDifferentialAndDoesNotCrash() throws {
        let output = try match([pcmTone(amplitude: 0.4, seconds: 1)], TTSLoudnessMatch())
        #expect(output.measurements.count == 1)
        #expect(output.measurements[0].appliedGainDB == 0)
    }

    @Test
    func anchorsToTheRobustMedianSoOneQuietOutlierDoesNotDragTheLoudChunks() throws {
        let segments = [
            pcmTone(amplitude: 0.5, seconds: 1),
            pcmTone(amplitude: 0.45, seconds: 1),
            pcmTone(amplitude: 0.4, seconds: 1),
            pcmTone(amplitude: 0.1, seconds: 1),
        ]
        let output = try match(segments, TTSLoudnessMatch(maxCorrectionDB: 12))
        let measured = try output.measurements.map { try #require($0.integratedLUFS) }
        let mean = measured.reduce(0, +) / Double(measured.count)
        #expect(measured[0] - mean > 3)
        #expect(abs(output.measurements[0].appliedGainDB) < 1.5)
        #expect(abs(output.measurements[1].appliedGainDB) < 1.5)
    }

    @Test
    func absoluteTargetIsReachedWhenTheGuardDoesNotFire() throws {
        let segments = [pcmTone(amplitude: 0.3, seconds: 1.5), pcmTone(amplitude: 0.2, seconds: 1.5)]
        let output = try match(segments, TTSLoudnessMatch(target: .lufs(-23), maxCorrectionDB: 3))
        #expect(output.summary.requestedTargetLUFS == -23)
        let achieved = try #require(output.summary.achievedLUFS)
        #expect(abs(achieved - -23) < 0.6)
        #expect(output.summary.appliedTrimDB == 0)
        let remetered = try #require(
            TTSLoudnessMeter.integratedLoudness(decodePCM(output.audio), sampleRate: 24000).lufs
        )
        #expect(abs(remetered - -23) < 0.6)
        for measurement in output.measurements {
            let level = try #require(measurement.integratedLUFS)
            #expect(abs((level + measurement.appliedGainDB) - achieved) < 0.6)
        }
    }

    @Test
    func absoluteTargetClampedByCeilingIsObservableNotSilent() throws {
        let segments = [pcmTone(amplitude: 0.7, seconds: 1.5), pcmTone(amplitude: 0.7, seconds: 1.5)]
        let output = try match(segments, TTSLoudnessMatch(target: .lufs(-3), truePeakCeilingDBTP: -1))
        #expect(output.summary.appliedTrimDB < 0)
        let achieved = try #require(output.summary.achievedLUFS)
        #expect(achieved < -3)
        let truePeak = try #require(output.summary.truePeakDBTP)
        #expect(truePeak <= -1 + 0.1)
        #expect(TTSLoudnessMeter.truePeakDBTP(decodePCM(output.audio)) <= -1 + 0.1)
    }

    @Test
    func absoluteTargetWithNoMeasurableProgramThrows() {
        let silence = Data(count: 24000 * 2)
        #expect(throws: TTSError.self) {
            _ = try match([silence], TTSLoudnessMatch(target: .lufs(-16)))
        }
    }

    @Test
    func shortLoudChunkIsUnmeasurableButStillPeakGuarded() throws {
        let segments = [
            pcmTone(amplitude: 0.3, seconds: 1),
            pcmTone(amplitude: 0.97, seconds: 0.2),
            pcmTone(amplitude: 0.3, seconds: 1),
        ]
        let output = try match(segments, TTSLoudnessMatch(truePeakCeilingDBTP: -1))
        #expect(output.measurements[1].integratedLUFS == nil)
        #expect(output.summary.appliedTrimDB < 0)
        let truePeak = try #require(output.summary.truePeakDBTP)
        #expect(truePeak <= -1 + 0.1)
        #expect(TTSLoudnessMeter.truePeakDBTP(decodePCM(output.audio)) <= -1 + 0.1)
    }

    @Test
    func clipGuardHoldsTheCeilingAcrossAZeroPauseSeam() throws {
        let hot = pcmTone(amplitude: 0.97, seconds: 1)
        let output = try match(
            [hot, hot],
            TTSLoudnessMatch(truePeakCeilingDBTP: -1),
            boundaries: [.withinSentence, .end]
        )
        let truePeak = try #require(output.summary.truePeakDBTP)
        #expect(truePeak <= -1 + 0.1)
        #expect(TTSLoudnessMeter.truePeakDBTP(decodePCM(output.audio)) <= -1 + 0.1)
    }

    @Test
    func assemblyPlacesRangesContiguouslyWithBoundaryPauses() throws {
        let segments = [pcmTone(amplitude: 0.5, seconds: 1), pcmTone(amplitude: 0.3, seconds: 1)]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(80))
        let output = try match(segments, TTSLoudnessMatch(), boundaries: [.sentence, .end], policy: policy)
        let pauseBytes = PCMSeam.frameCount(.milliseconds(80), sampleRate: 24000) * 2
        #expect(output.ranges[0] == 0 ..< 24000 * 2)
        #expect(output.ranges[1].lowerBound == output.ranges[0].upperBound + pauseBytes)
        #expect(output.audio.count == output.ranges[1].upperBound)
    }
}
