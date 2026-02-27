import Foundation
import Testing

@testable import AgentRunKit

@Suite
struct MP3ConcatenatorTests {
    @Test
    func emptyArrayReturnsEmptyData() {
        #expect(MP3Concatenator.concatenate([]) == Data())
    }

    @Test
    func singleSegmentWithoutMetadataPassesThrough() {
        let audio = Data([0xFF, 0xFB, 0x90, 0x00, 0x01, 0x02, 0x03])
        let result = MP3Concatenator.concatenate([audio])
        #expect(result == audio)
    }

    @Test
    func id3v2HeaderCorrectlyStripped() {
        var data = Data()
        data.append(contentsOf: [0x49, 0x44, 0x33]) // "ID3"
        data.append(contentsOf: [0x04, 0x00])
        data.append(0x00)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0A]) // syncsafe size = 10
        data.append(contentsOf: [UInt8](repeating: 0x00, count: 10))
        let audioPayload = Data([0xFF, 0xFB, 0x90, 0x00, 0xAA, 0xBB])
        data.append(audioPayload)

        let result = MP3Concatenator.stripID3v2Header(data)
        #expect(result == audioPayload)
    }

    @Test
    func id3v2WithExtendedHeaderCorrectlyStripped() {
        var data = Data()
        data.append(contentsOf: [0x49, 0x44, 0x33]) // "ID3"
        data.append(contentsOf: [0x04, 0x00])
        data.append(0x40) // extended header flag
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x14]) // syncsafe size = 20
        data.append(contentsOf: [UInt8](repeating: 0x00, count: 20))
        let audioPayload = Data([0xDE, 0xAD])
        data.append(audioPayload)

        let result = MP3Concatenator.stripID3v2Header(data)
        #expect(result == audioPayload)
    }

    @Test
    func xingFrameMPEG1StereoDetectedAndStripped() {
        let frame = buildMPEG1StereoXingFrame()
        let audioPayload = Data([0xAA, 0xBB, 0xCC])
        var data = frame
        data.append(audioPayload)

        let result = MP3Concatenator.stripXingFrame(data)
        #expect(result == audioPayload)
    }

    @Test
    func xingFrameMPEG2MonoDetectedAndStripped() {
        let frame = buildMPEG2MonoXingFrame()
        let audioPayload = Data([0xDD, 0xEE])
        var data = frame
        data.append(audioPayload)

        let result = MP3Concatenator.stripXingFrame(data)
        #expect(result == audioPayload)
    }

    @Test
    func infoFrameDetectedAndStripped() {
        var frame = buildMPEG1StereoXingFrame()
        frame[36] = 0x49 // I
        frame[37] = 0x6E // n
        frame[38] = 0x66 // f
        frame[39] = 0x6F // o
        let audioPayload = Data([0x11, 0x22])
        frame.append(contentsOf: audioPayload)

        let result = MP3Concatenator.stripXingFrame(frame)
        #expect(result == audioPayload)
    }

    @Test
    func id3v1TailCorrectlyStripped() {
        var data = Data([0xFF, 0xFB, 0x90, 0x00])
        var tag = Data([0x54, 0x41, 0x47]) // "TAG"
        tag.append(contentsOf: [UInt8](repeating: 0x00, count: 125))
        data.append(tag)

        let result = MP3Concatenator.stripID3v1Tail(data)
        #expect(result == Data([0xFF, 0xFB, 0x90, 0x00]))
    }

    @Test
    func fullConcatenationThreeSegments() {
        let audio1 = Data([0x01, 0x02])
        let audio2 = Data([0x03, 0x04])
        let audio3 = Data([0x05, 0x06])

        var seg1 = makeID3v2Header(contentSize: 0)
        seg1.append(audio1)
        seg1.append(makeID3v1Tag())

        var seg2 = makeID3v2Header(contentSize: 0)
        seg2.append(audio2)
        seg2.append(makeID3v1Tag())

        var seg3 = makeID3v2Header(contentSize: 0)
        seg3.append(audio3)
        seg3.append(makeID3v1Tag())

        let result = MP3Concatenator.concatenate([seg1, seg2, seg3])

        var expected = makeID3v2Header(contentSize: 0)
        expected.append(audio1)
        expected.append(audio2)
        expected.append(audio3)
        expected.append(makeID3v1Tag())

        #expect(result == expected)
    }

    @Test
    func dataWithoutID3OrXingPassesThroughUnchanged() {
        let audio = Data([0xFF, 0xFB, 0x90, 0x00, 0xAA, 0xBB, 0xCC, 0xDD])
        #expect(MP3Concatenator.stripID3v2Header(audio) == audio)
        #expect(MP3Concatenator.stripID3v1Tail(audio) == audio)
    }

    @Test
    func segmentWithOnlyID3v2Header() {
        let data = makeID3v2Header(contentSize: 0)
        let result = MP3Concatenator.stripID3v2Header(data)
        #expect(result.isEmpty)
    }

    @Test
    func unrecognizedMPEGVersionReturnsDataUnchanged() {
        // MPEG version bits = 0b01 (reserved)
        // 0xE8 = 1110_1000 → sync(111) version(01=reserved) layer(00) protection(0)
        var data = Data([0xFF, 0xE8, 0x90, 0x00])
        data.append(contentsOf: [UInt8](repeating: 0x00, count: 60))
        // Place "Xing" at offset 36 (where MPEG1 stereo would look)
        data[36] = 0x58
        data[37] = 0x69
        data[38] = 0x6E
        data[39] = 0x67
        let result = MP3Concatenator.stripXingFrame(data)
        #expect(result == data)
    }

    private func makeID3v2Header(contentSize: Int) -> Data {
        var data = Data()
        data.append(contentsOf: [0x49, 0x44, 0x33]) // "ID3"
        data.append(contentsOf: [0x04, 0x00]) // version 2.4.0
        data.append(0x00) // flags
        data.append(contentsOf: [
            UInt8((contentSize >> 21) & 0x7F),
            UInt8((contentSize >> 14) & 0x7F),
            UInt8((contentSize >> 7) & 0x7F),
            UInt8(contentSize & 0x7F)
        ])
        if contentSize > 0 {
            data.append(contentsOf: [UInt8](repeating: 0x00, count: contentSize))
        }
        return data
    }

    private func makeID3v1Tag() -> Data {
        var tag = Data([0x54, 0x41, 0x47]) // "TAG"
        tag.append(contentsOf: [UInt8](repeating: 0x00, count: 125))
        return tag
    }

    private func buildMPEG1StereoXingFrame() -> Data {
        // MPEG1 Layer III: 128kbps, 44100Hz, stereo → 144*128000/44100 = 417
        let frameSize = 417
        var frame = Data(count: frameSize)
        frame[0] = 0xFF
        frame[1] = 0xFB
        frame[2] = 0x90
        frame[3] = 0x00

        // Xing marker at offset 36 for MPEG1 stereo
        frame[36] = 0x58 // X
        frame[37] = 0x69 // i
        frame[38] = 0x6E // n
        frame[39] = 0x67 // g

        return frame
    }

    private func buildMPEG2MonoXingFrame() -> Data {
        // MPEG2 Layer III: 32kbps, 24000Hz, mono → 72*32000/24000 = 96
        let frameSize = 96
        var frame = Data(count: frameSize)
        frame[0] = 0xFF
        frame[1] = 0xF3
        frame[2] = 0x44
        frame[3] = 0xC0

        // Xing marker at offset 13 for MPEG2 mono
        frame[13] = 0x58 // X
        frame[14] = 0x69 // i
        frame[15] = 0x6E // n
        frame[16] = 0x67 // g

        return frame
    }
}
