@testable import AgentRunKit
import Foundation
import Testing

struct TTSAudioFormatTests {
    @Test
    func mimeTypeMatchesIANAOrConventionalValues() {
        #expect(TTSAudioFormat.mp3.mimeType == "audio/mpeg")
        #expect(TTSAudioFormat.opus.mimeType == "audio/opus")
        #expect(TTSAudioFormat.aac.mimeType == "audio/aac")
        #expect(TTSAudioFormat.flac.mimeType == "audio/flac")
        #expect(TTSAudioFormat.wav.mimeType == "audio/wav")
        #expect(TTSAudioFormat.pcm.mimeType == "audio/L16")
    }

    @Test
    func fileExtensionMatchesRawValueAcrossAllCases() {
        for format in TTSAudioFormat.allCases {
            #expect(format.fileExtension == format.rawValue)
        }
    }
}

struct TTSAudioEncodingTests {
    @Test
    func convenienceInitDerivesMimeAndExtensionFromFormat() {
        let encoding = TTSAudioEncoding(.mp3)
        #expect(encoding.format == .mp3)
        #expect(encoding.mimeType == "audio/mpeg")
        #expect(encoding.fileExtension == "mp3")
        #expect(encoding.sampleRate == nil)
        #expect(encoding.channels == nil)
        #expect(encoding.bitsPerSample == nil)
    }

    @Test
    func fullInitPreservesOverriddenMimeAndExtension() {
        let encoding = TTSAudioEncoding(
            format: .pcm,
            mimeType: "audio/L16; rate=24000",
            fileExtension: "raw",
            sampleRate: 24000,
            channels: 1,
            bitsPerSample: 16
        )
        #expect(encoding.format == .pcm)
        #expect(encoding.mimeType == "audio/L16; rate=24000")
        #expect(encoding.fileExtension == "raw")
        #expect(encoding.sampleRate == 24000)
        #expect(encoding.channels == 1)
        #expect(encoding.bitsPerSample == 16)
    }

    @Test
    func codableRoundTripPreservesAllFields() throws {
        let encoding = TTSAudioEncoding(
            format: .pcm,
            mimeType: "audio/L16",
            fileExtension: "pcm",
            sampleRate: 24000,
            channels: 1,
            bitsPerSample: 16
        )
        let data = try JSONEncoder().encode(encoding)
        let decoded = try JSONDecoder().decode(TTSAudioEncoding.self, from: data)
        #expect(decoded == encoding)
    }

    @Test
    func hashableUsableAsDictionaryKey() {
        let mp3Encoding = TTSAudioEncoding(.mp3)
        let mp3Duplicate = TTSAudioEncoding(.mp3)
        let wavEncoding = TTSAudioEncoding(.wav)
        var counts: [TTSAudioEncoding: Int] = [:]
        counts[mp3Encoding, default: 0] += 1
        counts[mp3Duplicate, default: 0] += 1
        counts[wavEncoding, default: 0] += 1
        #expect(counts[mp3Encoding] == 2)
        #expect(counts[wavEncoding] == 1)
    }
}

struct TTSChunkTests {
    @Test
    func codableRoundTripPreservesAllFields() throws {
        let chunk = TTSChunk(
            index: 2,
            total: 5,
            text: "Hello world.",
            sourceRange: 4 ..< 16,
            trailingBoundary: .sentence
        )
        let data = try JSONEncoder().encode(chunk)
        let decoded = try JSONDecoder().decode(TTSChunk.self, from: data)
        #expect(decoded == chunk)
    }

    @Test
    func hashableUsableAsDictionaryKey() {
        let firstChunk = TTSChunk(index: 0, total: 1, text: "x", sourceRange: 0 ..< 1, trailingBoundary: .end)
        let firstDuplicate = TTSChunk(index: 0, total: 1, text: "x", sourceRange: 0 ..< 1, trailingBoundary: .end)
        let secondChunk = TTSChunk(index: 1, total: 2, text: "y", sourceRange: 1 ..< 2, trailingBoundary: .sentence)
        var counts: [TTSChunk: Int] = [:]
        counts[firstChunk, default: 0] += 1
        counts[firstDuplicate, default: 0] += 1
        counts[secondChunk, default: 0] += 1
        #expect(counts[firstChunk] == 2)
        #expect(counts[secondChunk] == 1)
    }
}

struct TTSSegmentTimingTests {
    @Test
    func uncomputedHasNilFields() {
        let timing = TTSSegmentTiming.uncomputed
        #expect(timing.byteRangeInConcatenatedAudio == nil)
        #expect(timing.durationSeconds == nil)
    }

    @Test
    func codableRoundTripPreservesPopulatedFields() throws {
        let timing = TTSSegmentTiming(byteRangeInConcatenatedAudio: 0 ..< 1024, durationSeconds: 1.25)
        let data = try JSONEncoder().encode(timing)
        let decoded = try JSONDecoder().decode(TTSSegmentTiming.self, from: data)
        #expect(decoded == timing)
    }

    @Test
    func codableRoundTripPreservesNilFields() throws {
        let timing = TTSSegmentTiming.uncomputed
        let data = try JSONEncoder().encode(timing)
        let decoded = try JSONDecoder().decode(TTSSegmentTiming.self, from: data)
        #expect(decoded == timing)
    }
}

struct TTSChunkContextTests {
    @Test
    func codableRoundTripPreservesAllFields() throws {
        let context = TTSChunkContext(
            chunk: TTSChunk(index: 1, total: 3, text: "middle", sourceRange: 7 ..< 13, trailingBoundary: .sentence),
            encoding: TTSAudioEncoding(.mp3)
        )
        let data = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(TTSChunkContext.self, from: data)
        #expect(decoded == context)
    }
}

struct TTSManifestEntryTests {
    @Test
    func codableRoundTripPreservesAllFields() throws {
        let entry = TTSManifestEntry(
            chunk: TTSChunk(index: 0, total: 2, text: "first", sourceRange: 0 ..< 5, trailingBoundary: .sentence),
            encoding: TTSAudioEncoding(
                format: .pcm,
                mimeType: "audio/L16",
                fileExtension: "pcm",
                sampleRate: 24000,
                channels: 1,
                bitsPerSample: 16
            ),
            timing: TTSSegmentTiming(byteRangeInConcatenatedAudio: 0 ..< 48000, durationSeconds: 1.0)
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(TTSManifestEntry.self, from: data)
        #expect(decoded == entry)
    }

    @Test
    func wireFormatLocksJSONKeysWithPopulatedFields() throws {
        let entry = TTSManifestEntry(
            chunk: TTSChunk(index: 0, total: 2, text: "Hi.", sourceRange: 0 ..< 3, trailingBoundary: .sentence),
            encoding: TTSAudioEncoding(
                format: .pcm,
                mimeType: "audio/L16",
                fileExtension: "pcm",
                sampleRate: 24000,
                channels: 1,
                bitsPerSample: 16
            ),
            timing: TTSSegmentTiming(byteRangeInConcatenatedAudio: 0 ..< 12, durationSeconds: 0.5)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry)
        let json = try #require(String(data: data, encoding: .utf8))
        let expected =
            #"{"chunk":{"index":0,"sourceRange":[0,3],"text":"Hi.","total":2,"trailingBoundary":"sentence"},"#
                + #""encoding":{"bitsPerSample":16,"channels":1,"fileExtension":"pcm","#
                + #""format":"pcm","mimeType":"audio\/L16","sampleRate":24000},"#
                + #""timing":{"byteRangeInConcatenatedAudio":[0,12],"durationSeconds":0.5}}"#
        #expect(json == expected)
    }

    @Test
    func wireFormatOmitsNilOptionalFields() throws {
        let entry = TTSManifestEntry(
            chunk: TTSChunk(index: 0, total: 1, text: "Hi.", sourceRange: 0 ..< 3, trailingBoundary: .end),
            encoding: TTSAudioEncoding(.mp3),
            timing: .uncomputed
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry)
        let json = try #require(String(data: data, encoding: .utf8))
        let expected =
            #"{"chunk":{"index":0,"sourceRange":[0,3],"text":"Hi.","total":1,"trailingBoundary":"end"},"#
                + #""encoding":{"fileExtension":"mp3","format":"mp3","mimeType":"audio\/mpeg"},"#
                + #""timing":{}}"#
        #expect(json == expected)
    }

    @Test
    func wireFormatLocksLoudnessKeysWhenPopulated() throws {
        let entry = TTSManifestEntry(
            chunk: TTSChunk(index: 0, total: 1, text: "Hi.", sourceRange: 0 ..< 3, trailingBoundary: .end),
            encoding: TTSAudioEncoding(
                format: .pcm,
                mimeType: "audio/L16",
                fileExtension: "pcm",
                sampleRate: 24000,
                channels: 1,
                bitsPerSample: 16
            ),
            timing: TTSSegmentTiming(byteRangeInConcatenatedAudio: 0 ..< 12, durationSeconds: 0.5),
            loudness: TTSLoudnessMeasurement(integratedLUFS: -18.5, appliedGainDB: 1.25)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try #require(try String(data: encoder.encode(entry), encoding: .utf8))
        let expected =
            #"{"chunk":{"index":0,"sourceRange":[0,3],"text":"Hi.","total":1,"trailingBoundary":"end"},"#
                + #""encoding":{"bitsPerSample":16,"channels":1,"fileExtension":"pcm","#
                + #""format":"pcm","mimeType":"audio\/L16","sampleRate":24000},"#
                + #""loudness":{"appliedGainDB":1.25,"integratedLUFS":-18.5},"#
                + #""timing":{"byteRangeInConcatenatedAudio":[0,12],"durationSeconds":0.5}}"#
        #expect(json == expected)
    }
}

struct TTSConcatenationResultTests {
    @Test
    func memberwiseInitPreservesFields() {
        let entry = TTSManifestEntry(
            chunk: TTSChunk(index: 0, total: 1, text: "x", sourceRange: 0 ..< 1, trailingBoundary: .end),
            encoding: TTSAudioEncoding(.wav),
            timing: .uncomputed
        )
        let result = TTSConcatenationResult(audio: Data([0x01, 0x02]), manifest: [entry])
        #expect(result.audio == Data([0x01, 0x02]))
        #expect(result.manifest == [entry])
    }
}

private struct DefaultEncodingProvider: TTSProvider {
    let config = TTSProviderConfig(
        maxChunkCharacters: 100,
        defaultVoice: "voice",
        defaultFormat: .pcm
    )

    func generate(
        text _: String,
        voice _: String,
        options _: TTSOptions,
        context _: TTSChunkContext
    ) async -> Data {
        Data()
    }
}

struct TTSProviderResolvedEncodingDefaultTests {
    @Test
    func defaultImplementationReturnsFormatBackedEncodingWithNilPCMFields() {
        let provider = DefaultEncodingProvider()
        for format in TTSAudioFormat.allCases {
            let encoding = provider.resolvedEncoding(for: format, options: TTSOptions())
            #expect(encoding.format == format)
            #expect(encoding.mimeType == format.mimeType)
            #expect(encoding.fileExtension == format.fileExtension)
            #expect(encoding.sampleRate == nil)
            #expect(encoding.channels == nil)
            #expect(encoding.bitsPerSample == nil)
        }
    }

    @Test
    func defaultImplementationIgnoresOptionsValues() {
        let provider = DefaultEncodingProvider()
        let opts = TTSOptions(speed: 1.25, responseFormat: .mp3)
        let viaPCM = provider.resolvedEncoding(for: .pcm, options: opts)
        let viaMP3 = provider.resolvedEncoding(for: .mp3, options: opts)
        #expect(viaPCM.format == .pcm)
        #expect(viaMP3.format == .mp3)
        #expect(viaPCM.sampleRate == nil)
        #expect(viaMP3.sampleRate == nil)
    }
}

struct TTSBoundaryTests {
    @Test
    func rawValuesLockWireFormat() {
        #expect(TTSBoundary.sentence.rawValue == "sentence")
        #expect(TTSBoundary.paragraph.rawValue == "paragraph")
        #expect(TTSBoundary.withinSentence.rawValue == "withinSentence")
        #expect(TTSBoundary.end.rawValue == "end")
    }
}

struct TTSStitchPolicyTests {
    @Test
    func codableRoundTripPreservesAllFields() throws {
        let policy = TTSStitchPolicy(
            targetCharacters: 240,
            preferParagraphBoundaries: true,
            sentencePause: .milliseconds(200),
            paragraphPause: .milliseconds(600),
            joinFade: .milliseconds(6),
            loudness: TTSLoudnessMatch(target: .lufs(-16), maxCorrectionDB: 2, truePeakCeilingDBTP: -2)
        )
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(TTSStitchPolicy.self, from: data)
        #expect(decoded == policy)
    }

    @Test
    func defaultsAreGreedyWithNoPausesOrFade() {
        let policy = TTSStitchPolicy()
        #expect(policy.targetCharacters == nil)
        #expect(policy.preferParagraphBoundaries == false)
        #expect(policy.sentencePause == .zero)
        #expect(policy.paragraphPause == .zero)
        #expect(policy.joinFade == .zero)
        #expect(policy.loudness == nil)
    }
}

struct TTSLoudnessMatchTests {
    @Test
    func defaultsAreProgramMedianWithStandardClampAndCeiling() {
        let match = TTSLoudnessMatch()
        #expect(match.target == .programMedian)
        #expect(match.maxCorrectionDB == 3.0)
        #expect(match.truePeakCeilingDBTP == -1.0)
    }

    @Test
    func codableRoundTripPreservesTargetAndKnobs() throws {
        for target in [TTSLoudnessMatch.Target.programMedian, .lufs(-16)] {
            let match = TTSLoudnessMatch(target: target, maxCorrectionDB: 2, truePeakCeilingDBTP: -2)
            let data = try JSONEncoder().encode(match)
            #expect(try JSONDecoder().decode(TTSLoudnessMatch.self, from: data) == match)
        }
    }

    @Test
    func wireFormatLocksMatchKeys() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let median = TTSLoudnessMatch(maxCorrectionDB: 3, truePeakCeilingDBTP: -1)
        #expect(try String(data: encoder.encode(median), encoding: .utf8) ==
            #"{"maxCorrectionDB":3,"target":{"programMedian":{}},"truePeakCeilingDBTP":-1}"#)
        let absolute = TTSLoudnessMatch(target: .lufs(-16), maxCorrectionDB: 2, truePeakCeilingDBTP: -2)
        #expect(try String(data: encoder.encode(absolute), encoding: .utf8) ==
            #"{"maxCorrectionDB":2,"target":{"lufs":{"_0":-16}},"truePeakCeilingDBTP":-2}"#)
    }

    @Test
    func decodingRejectsOutOfDomainKnobs() {
        let decoder = JSONDecoder()
        let negativeClamp = #"{"maxCorrectionDB":-3,"target":{"programMedian":{}},"truePeakCeilingDBTP":-1}"#
        #expect(throws: DecodingError.self) {
            try decoder.decode(TTSLoudnessMatch.self, from: Data(negativeClamp.utf8))
        }
        let positiveTarget = #"{"maxCorrectionDB":3,"target":{"lufs":{"_0":5}},"truePeakCeilingDBTP":-1}"#
        #expect(throws: DecodingError.self) {
            try decoder.decode(TTSLoudnessMatch.self, from: Data(positiveTarget.utf8))
        }
    }
}

struct TTSLoudnessMeasurementTests {
    @Test
    func measurementCodableRoundTripPreservesMeasuredAndUnmeasuredFields() throws {
        for lufs in [Double?.none, -18.5] {
            let measurement = TTSLoudnessMeasurement(integratedLUFS: lufs, appliedGainDB: 1.25)
            let data = try JSONEncoder().encode(measurement)
            #expect(try JSONDecoder().decode(TTSLoudnessMeasurement.self, from: data) == measurement)
        }
    }

    @Test
    func summaryCodableRoundTripPreservesFields() throws {
        let summary = TTSLoudnessSummary(
            achievedLUFS: -16.1,
            requestedTargetLUFS: -16,
            appliedTrimDB: -0.4,
            truePeakDBTP: -1.0
        )
        let data = try JSONEncoder().encode(summary)
        #expect(try JSONDecoder().decode(TTSLoudnessSummary.self, from: data) == summary)
    }

    @Test
    func wireFormatLocksMeasurementKeysAndOmitsNilLUFS() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let measured = TTSLoudnessMeasurement(integratedLUFS: -18.5, appliedGainDB: 1.25)
        #expect(try String(data: encoder.encode(measured), encoding: .utf8) ==
            #"{"appliedGainDB":1.25,"integratedLUFS":-18.5}"#)
        let unmeasured = TTSLoudnessMeasurement(integratedLUFS: nil, appliedGainDB: 0.5)
        #expect(try String(data: encoder.encode(unmeasured), encoding: .utf8) ==
            #"{"appliedGainDB":0.5}"#)
    }

    @Test
    func wireFormatLocksSummaryKeysAndOmitsNilFields() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let summary = TTSLoudnessSummary(
            achievedLUFS: -16.1, requestedTargetLUFS: -16, appliedTrimDB: -0.4, truePeakDBTP: -1.0
        )
        #expect(try String(data: encoder.encode(summary), encoding: .utf8) ==
            #"{"achievedLUFS":-16.1,"appliedTrimDB":-0.4,"requestedTargetLUFS":-16,"truePeakDBTP":-1}"#)
        let bare = TTSLoudnessSummary(
            achievedLUFS: nil, requestedTargetLUFS: nil, appliedTrimDB: 0, truePeakDBTP: nil
        )
        #expect(try String(data: encoder.encode(bare), encoding: .utf8) ==
            #"{"appliedTrimDB":0}"#)
    }
}
