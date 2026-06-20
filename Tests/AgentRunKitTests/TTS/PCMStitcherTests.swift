@testable import AgentRunKit
import Foundation
import Testing

private let stitchFormat: PCMFormat = {
    guard let format = PCMFormat(TTSAudioEncoding(.pcm, sampleRate: 24000, channels: 1, bitsPerSample: 16)) else {
        preconditionFailure("test fixture encoding must be valid 16-bit PCM")
    }
    return format
}()

private func pcmFrames(_ count: Int, sample: Int16) -> Data {
    var data = Data(capacity: count * 2)
    let bits = UInt16(bitPattern: sample)
    for _ in 0 ..< count {
        data.append(UInt8(bits & 0x00FF))
        data.append(UInt8(bits >> 8))
    }
    return data
}

private func sample(_ data: Data, frame: Int) -> Int16 {
    let index = data.startIndex + frame * 2
    return Int16(bitPattern: UInt16(data[index]) | (UInt16(data[index + 1]) << 8))
}

private func smoothstep(step: Int, fade: Int) -> Double {
    let position = (Double(step) + 0.5) / Double(fade)
    return position * position * (3 - 2 * position)
}

private func stitch(
    _ segments: [Data],
    _ boundaries: [TTSBoundary],
    _ policy: TTSStitchPolicy
) -> (audio: Data, ranges: [Range<Int>]) {
    PCMStitcher.stitch(segments: segments, boundaries: boundaries, policy: policy, format: stitchFormat)
}

struct PCMStitcherTests {
    @Test
    func sentenceAndParagraphSeamsInsertSilenceOfExpectedSize() {
        let segments = [pcmFrames(100, sample: 5000), pcmFrames(100, sample: 5000), pcmFrames(100, sample: 5000)]
        let boundaries: [TTSBoundary] = [.sentence, .paragraph, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(100), paragraphPause: .milliseconds(500))
        let result = stitch(segments, boundaries, policy)

        let sentenceBytes = 4800
        let paragraphBytes = 24000
        #expect(result.ranges == [
            0 ..< 200,
            (200 + sentenceBytes) ..< (400 + sentenceBytes),
            (400 + sentenceBytes + paragraphBytes) ..< (600 + sentenceBytes + paragraphBytes),
        ])
        #expect(result.audio.count == 600 + sentenceBytes + paragraphBytes)

        let firstGap = result.audio.subdata(in: result.ranges[0].upperBound ..< result.ranges[1].lowerBound)
        #expect(firstGap.count == sentenceBytes)
        #expect(firstGap.allSatisfy { $0 == 0 })
        let secondGap = result.audio.subdata(in: result.ranges[1].upperBound ..< result.ranges[2].lowerBound)
        #expect(secondGap.count == paragraphBytes)
        #expect(secondGap.allSatisfy { $0 == 0 })
    }

    @Test
    func withinSentenceAndEndSeamsInsertNoSilence() {
        let segments = [pcmFrames(50, sample: 3000), pcmFrames(50, sample: 3000), pcmFrames(50, sample: 3000)]
        let boundaries: [TTSBoundary] = [.withinSentence, .sentence, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(100), paragraphPause: .milliseconds(500))
        let result = stitch(segments, boundaries, policy)

        #expect(result.ranges[0] == 0 ..< 100)
        #expect(result.ranges[1] == 100 ..< 200)
        #expect(result.ranges[2].lowerBound == 200 + 4800)
        #expect(result.audio.count == 300 + 4800)
    }

    @Test
    func zeroPausesReproduceRawConcatenation() {
        let segments = [pcmFrames(40, sample: 1234), pcmFrames(40, sample: -2345)]
        let boundaries: [TTSBoundary] = [.sentence, .end]
        let result = stitch(segments, boundaries, TTSStitchPolicy())
        var raw = Data()
        for segment in segments {
            raw.append(segment)
        }
        #expect(result.audio == raw)
        #expect(result.ranges == [0 ..< 80, 80 ..< 160])
    }

    @Test
    func identicalInputsProduceIdenticalBytes() {
        let segments = [pcmFrames(300, sample: 8000), pcmFrames(300, sample: 8000)]
        let boundaries: [TTSBoundary] = [.sentence, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(80), joinFade: .milliseconds(5))
        let first = stitch(segments, boundaries, policy)
        let second = stitch(segments, boundaries, policy)
        #expect(first.audio == second.audio)
        #expect(first.ranges == second.ranges)
    }

    @Test
    func joinFadeAttenuatesOnlyEdgesAdjacentToPauses() {
        let level: Int16 = 10000
        let segments = [pcmFrames(1000, sample: level), pcmFrames(1000, sample: level)]
        let boundaries: [TTSBoundary] = [.sentence, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(50), joinFade: .milliseconds(5))
        let result = stitch(segments, boundaries, policy)

        let seg0 = result.audio.subdata(in: result.ranges[0])
        let seg1 = result.audio.subdata(in: result.ranges[1])

        #expect(sample(seg0, frame: 0) == level)
        #expect(sample(seg0, frame: 500) == level)
        #expect(sample(seg0, frame: 999) < level)
        #expect(sample(seg0, frame: 999) >= 0)

        #expect(sample(seg1, frame: 0) < level)
        #expect(sample(seg1, frame: 0) >= 0)
        #expect(sample(seg1, frame: 999) == level)
    }

    @Test
    func fadeFollowsSmoothstepCurveOnBipolarSignal() {
        let level: Int16 = -10000
        let segments = [pcmFrames(1000, sample: level), pcmFrames(1000, sample: level)]
        let boundaries: [TTSBoundary] = [.sentence, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(50), joinFade: .milliseconds(5))
        let result = stitch(segments, boundaries, policy)

        let seg0 = result.audio.subdata(in: result.ranges[0])
        let fade = 120
        for offset in [0, 59, 119] {
            let expected = Int16((Double(level) * smoothstep(step: offset, fade: fade)).rounded())
            #expect(sample(seg0, frame: 999 - offset) == expected)
        }
        #expect(sample(seg0, frame: 400) == level)
    }

    @Test
    func withinSentenceSeamGetsNoFadeWithJoinFadeSet() {
        let level: Int16 = 10000
        let segments = [pcmFrames(500, sample: level), pcmFrames(500, sample: level), pcmFrames(500, sample: level)]
        let boundaries: [TTSBoundary] = [.withinSentence, .sentence, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(50), joinFade: .milliseconds(5))
        let result = stitch(segments, boundaries, policy)

        let seg0 = result.audio.subdata(in: result.ranges[0])
        let seg1 = result.audio.subdata(in: result.ranges[1])
        #expect(sample(seg0, frame: 499) == level)
        #expect(sample(seg1, frame: 0) == level)
        #expect(sample(seg1, frame: 499) < level)
    }
}
