import Foundation

enum PCMStitcher {
    static func stitch(
        segments: [Data],
        boundaries: [TTSBoundary],
        policy: TTSStitchPolicy,
        format: PCMFormat
    ) -> (audio: Data, ranges: [Range<Int>]) {
        precondition(segments.count == boundaries.count, "segments and boundaries must be aligned")

        let bytesPerFrame = format.bytesPerFrame
        let sentencePause = PCMSeam.frameCount(policy.sentencePause, sampleRate: format.sampleRate)
        let paragraphPause = PCMSeam.frameCount(policy.paragraphPause, sampleRate: format.sampleRate)
        let fadeFrames = PCMSeam.frameCount(policy.joinFade, sampleRate: format.sampleRate)

        var audio = Data()
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(segments.count)

        for index in segments.indices {
            let trailingPause = PCMSeam.pauseFrames(
                for: boundaries[index],
                sentence: sentencePause,
                paragraph: paragraphPause
            )
            let leadingPause = index > 0
                ? PCMSeam.pauseFrames(for: boundaries[index - 1], sentence: sentencePause, paragraph: paragraphPause)
                : 0

            var segment = segments[index]
            if fadeFrames > 0 {
                applyEdgeFades(
                    &segment,
                    fadeIn: leadingPause > 0,
                    fadeOut: trailingPause > 0,
                    fadeFrames: fadeFrames,
                    bytesPerFrame: bytesPerFrame
                )
            }

            let lower = audio.count
            audio.append(segment)
            ranges.append(lower ..< audio.count)
            if trailingPause > 0 {
                audio.append(Data(count: trailingPause * bytesPerFrame))
            }
        }

        return (audio, ranges)
    }

    private static func applyEdgeFades(
        _ segment: inout Data,
        fadeIn: Bool,
        fadeOut: Bool,
        fadeFrames: Int,
        bytesPerFrame: Int
    ) {
        guard fadeIn || fadeOut else { return }
        let channels = bytesPerFrame / 2
        let totalFrames = segment.count / bytesPerFrame
        guard totalFrames > 0, channels > 0 else { return }

        let available = (fadeIn && fadeOut) ? totalFrames / 2 : totalFrames
        let fade = min(fadeFrames, available)
        guard fade > 0 else { return }

        var bytes = [UInt8](segment)
        if fadeIn {
            for frame in 0 ..< fade {
                scaleFrame(
                    &bytes,
                    frame: frame,
                    gain: PCMSeam.fadeGain(step: frame, fade: fade),
                    channels: channels,
                    bytesPerFrame: bytesPerFrame
                )
            }
        }
        if fadeOut {
            for offset in 0 ..< fade {
                scaleFrame(
                    &bytes,
                    frame: totalFrames - 1 - offset,
                    gain: PCMSeam.fadeGain(step: offset, fade: fade),
                    channels: channels,
                    bytesPerFrame: bytesPerFrame
                )
            }
        }
        segment = Data(bytes)
    }

    private static func scaleFrame(
        _ bytes: inout [UInt8],
        frame: Int,
        gain: Double,
        channels: Int,
        bytesPerFrame: Int
    ) {
        let frameStart = frame * bytesPerFrame
        for channel in 0 ..< channels {
            let low = frameStart + channel * 2
            let sample = Int16(bitPattern: UInt16(bytes[low]) | (UInt16(bytes[low + 1]) << 8))
            let scaled = Int16((Double(sample) * gain).rounded())
            let bits = UInt16(bitPattern: scaled)
            bytes[low] = UInt8(bits & 0x00FF)
            bytes[low + 1] = UInt8(bits >> 8)
        }
    }
}
