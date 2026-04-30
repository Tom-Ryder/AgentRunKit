import Foundation

enum MP3Concatenator {
    static func concatenate(_ segments: [Data]) -> Data {
        concatenateWithRanges(segments).audio
    }

    static func concatenateWithRanges(_ segments: [Data]) -> (audio: Data, ranges: [Range<Int>]) {
        guard !segments.isEmpty else { return (Data(), []) }

        var result = Data()
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(segments.count)
        for (index, segment) in segments.enumerated() {
            var data = segment
            if index > 0 {
                data = stripID3v2Header(data)
            }
            data = stripXingFrame(data)
            if index < segments.count - 1 {
                data = stripID3v1Tail(data)
            }
            let lower = result.count
            result.append(data)
            ranges.append(lower ..< result.count)
        }
        return (result, ranges)
    }

    static func stripID3v2Header(_ data: Data) -> Data {
        guard data.count >= 10,
              data[0] == 0x49, data[1] == 0x44, data[2] == 0x33
        else { return data }

        let size = decodeSyncsafe(data[6], data[7], data[8], data[9])
        let headerSize = 10 + size
        guard headerSize <= data.count else { return data }
        return data.subdata(in: headerSize ..< data.count)
    }

    static func stripXingFrame(_ data: Data) -> Data {
        guard let syncOffset = findMPEGSyncWord(data),
              syncOffset + 4 <= data.count
        else { return data }

        guard let header = readFrameHeader(data, at: syncOffset) else { return data }

        guard let xingOffset = xingMarkerOffset(version: header.version, channelMode: header.channelMode)
        else { return data }

        let markerPosition = syncOffset + xingOffset
        guard markerPosition + 4 <= data.count else { return data }

        let isXing = data[markerPosition] == 0x58
            && data[markerPosition + 1] == 0x69
            && data[markerPosition + 2] == 0x6E
            && data[markerPosition + 3] == 0x67
        let isInfo = data[markerPosition] == 0x49
            && data[markerPosition + 1] == 0x6E
            && data[markerPosition + 2] == 0x66
            && data[markerPosition + 3] == 0x6F

        guard isXing || isInfo else { return data }

        guard let frameSize = computeFrameSize(header) else { return data }
        let frameEnd = syncOffset + frameSize
        guard frameEnd <= data.count else { return data }

        var result = data.subdata(in: 0 ..< syncOffset)
        result.append(data.subdata(in: frameEnd ..< data.count))
        return result
    }

    static func stripID3v1Tail(_ data: Data) -> Data {
        guard data.count >= 128 else { return data }
        let tagStart = data.count - 128
        guard data[tagStart] == 0x54,
              data[tagStart + 1] == 0x41,
              data[tagStart + 2] == 0x47
        else { return data }
        return data.subdata(in: 0 ..< tagStart)
    }

    private enum MPEGVersion {
        case mpeg1, mpeg2, mpeg25
    }

    private struct FrameHeader {
        let version: MPEGVersion
        let channelMode: UInt8
        let bitrateIndex: UInt8
        let sampleRateIndex: UInt8
        let padding: Bool
    }

    private static func findMPEGSyncWord(_ data: Data) -> Int? {
        guard data.count >= 2 else { return nil }
        for offset in 0 ..< data.count - 1 {
            if data[offset] == 0xFF, data[offset + 1] & 0xE0 == 0xE0 {
                return offset
            }
        }
        return nil
    }

    private static func readFrameHeader(_ data: Data, at offset: Int) -> FrameHeader? {
        let byte1 = data[offset + 1]
        let byte2 = data[offset + 2]
        let byte3 = data[offset + 3]

        let versionBits = (byte1 >> 3) & 0x03
        let version: MPEGVersion
        switch versionBits {
        case 0b11: version = .mpeg1
        case 0b10: version = .mpeg2
        case 0b00: version = .mpeg25
        default: return nil
        }

        let layerBits = (byte1 >> 1) & 0x03
        guard layerBits == 0b01 else { return nil }

        return FrameHeader(
            version: version,
            channelMode: (byte3 >> 6) & 0x03,
            bitrateIndex: (byte2 >> 4) & 0x0F,
            sampleRateIndex: (byte2 >> 2) & 0x03,
            padding: (byte2 >> 1) & 0x01 == 1
        )
    }

    private static func xingMarkerOffset(version: MPEGVersion, channelMode: UInt8) -> Int? {
        let isMono = channelMode == 0b11
        switch version {
        case .mpeg1: return isMono ? 21 : 36
        case .mpeg2, .mpeg25: return isMono ? 13 : 21
        }
    }

    private static func computeFrameSize(_ header: FrameHeader) -> Int? {
        guard let bitrate = lookupBitrate(version: header.version, index: header.bitrateIndex),
              let sampleRate = lookupSampleRate(version: header.version, index: header.sampleRateIndex),
              bitrate > 0, sampleRate > 0
        else { return nil }
        let multiplier = switch header.version {
        case .mpeg1: 144
        case .mpeg2, .mpeg25: 72
        }
        return multiplier * bitrate / sampleRate + (header.padding ? 1 : 0)
    }

    private static let bitrateTableV1: [Int] = [
        0, 32000, 40000, 48000, 56000, 64000, 80000, 96000,
        112_000, 128_000, 160_000, 192_000, 224_000, 256_000, 320_000, 0
    ]

    private static let bitrateTableV2: [Int] = [
        0, 8000, 16000, 24000, 32000, 40000, 48000, 56000,
        64000, 80000, 96000, 112_000, 128_000, 144_000, 160_000, 0
    ]

    private static let sampleRateTableV1: [Int] = [44100, 48000, 32000, 0]
    private static let sampleRateTableV2: [Int] = [22050, 24000, 16000, 0]
    private static let sampleRateTableV25: [Int] = [11025, 12000, 8000, 0]

    private static func lookupBitrate(version: MPEGVersion, index: UInt8) -> Int? {
        let idx = Int(index)
        let table = switch version {
        case .mpeg1: bitrateTableV1
        case .mpeg2, .mpeg25: bitrateTableV2
        }
        guard idx < table.count else { return nil }
        return table[idx]
    }

    private static func lookupSampleRate(version: MPEGVersion, index: UInt8) -> Int? {
        let idx = Int(index)
        let table = switch version {
        case .mpeg1: sampleRateTableV1
        case .mpeg2: sampleRateTableV2
        case .mpeg25: sampleRateTableV25
        }
        guard idx < table.count else { return nil }
        return table[idx]
    }

    private static func decodeSyncsafe(_ byte0: UInt8, _ byte1: UInt8, _ byte2: UInt8, _ byte3: UInt8) -> Int {
        (Int(byte0) << 21) | (Int(byte1) << 14) | (Int(byte2) << 7) | Int(byte3)
    }
}
