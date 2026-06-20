import Foundation

struct PCMFormat: Equatable {
    let sampleRate: Int
    let channels: Int

    init?(_ encoding: TTSAudioEncoding) {
        guard encoding.format == .pcm,
              encoding.bitsPerSample == 16,
              let sampleRate = encoding.sampleRate, sampleRate > 0,
              let channels = encoding.channels, channels > 0
        else { return nil }
        let (bytesPerFrame, frameOverflow) = channels.multipliedReportingOverflow(by: 2)
        let (bytesPerSecond, secondOverflow) = sampleRate.multipliedReportingOverflow(by: bytesPerFrame)
        guard !frameOverflow, !secondOverflow, bytesPerSecond > 0 else { return nil }
        self.sampleRate = sampleRate
        self.channels = channels
    }

    var bytesPerFrame: Int {
        channels * 2
    }

    var bytesPerSecond: Int {
        sampleRate * bytesPerFrame
    }
}
