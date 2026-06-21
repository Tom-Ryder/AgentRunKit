import Foundation

enum TTSLoudnessReading: Equatable {
    case measured(Double)
    case unmeasurable(Reason)

    enum Reason: Equatable {
        case shorterThanGatingBlock
        case belowAbsoluteGate
    }

    var lufs: Double? {
        if case let .measured(value) = self { return value }
        return nil
    }
}

enum TTSLoudnessMeter {
    static func integratedLoudness(_ samples: [Double], sampleRate: Int) -> TTSLoudnessReading {
        let powers = blockPowers(samples, sampleRate: sampleRate)
        guard !powers.isEmpty else { return .unmeasurable(.shorterThanGatingBlock) }
        let absoluteGated = powers.filter { blockLoudness($0) > absoluteGate }
        guard !absoluteGated.isEmpty else { return .unmeasurable(.belowAbsoluteGate) }
        let meanAbsolute = absoluteGated.reduce(0, +) / Double(absoluteGated.count)
        let relativeThreshold = offset + 10 * log10(meanAbsolute) - relativeGate
        let gate = max(absoluteGate, relativeThreshold)
        let gated = powers.filter { blockLoudness($0) > gate }
        guard !gated.isEmpty else { return .unmeasurable(.belowAbsoluteGate) }
        let meanGated = gated.reduce(0, +) / Double(gated.count)
        return .measured(offset + 10 * log10(meanGated))
    }

    static func truePeakDBTP(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return -.infinity }
        var peak = 0.0
        for sample in samples {
            peak = max(peak, abs(sample))
        }
        for phase in interpolatorPhases {
            let taps = phase.count
            for index in 0 ..< samples.count + taps - 1 {
                var accumulator = 0.0
                for tap in 0 ..< taps where index - tap >= 0 && index - tap < samples.count {
                    accumulator += phase[tap] * samples[index - tap]
                }
                peak = max(peak, abs(accumulator))
            }
        }
        return peak > 0 ? 20 * log10(peak) : -.infinity
    }

    private static let offset = -0.691
    private static let absoluteGate = -70.0
    private static let relativeGate = 10.0

    private static func blockLoudness(_ power: Double) -> Double {
        power > 0 ? offset + 10 * log10(power) : -.infinity
    }

    private static func blockPowers(_ samples: [Double], sampleRate: Int) -> [Double] {
        let weighted = kWeightHighPass(sampleRate: sampleRate)
            .process(kWeightShelf(sampleRate: sampleRate).process(samples))
        let step = sampleRate / 10
        let block = 4 * step
        guard step > 0, weighted.count >= block else { return [] }
        var powers: [Double] = []
        var start = 0
        while start + block <= weighted.count {
            var sum = 0.0
            for index in start ..< start + block {
                sum += weighted[index] * weighted[index]
            }
            powers.append(sum / Double(block))
            start += step
        }
        return powers
    }

    private struct Biquad {
        let feedforward0, feedforward1, feedforward2: Double
        let feedback1, feedback2: Double

        func process(_ input: [Double]) -> [Double] {
            var output = [Double](repeating: 0, count: input.count)
            var stateOne = 0.0
            var stateTwo = 0.0
            for index in input.indices {
                let sample = input[index]
                let result = feedforward0 * sample + stateOne
                stateOne = feedforward1 * sample - feedback1 * result + stateTwo
                stateTwo = feedforward2 * sample - feedback2 * result
                output[index] = result
            }
            return output
        }
    }

    private static func kWeightShelf(sampleRate: Int) -> Biquad {
        let cutoff = 1681.974450955533
        let gain = 3.999843853973347
        let quality = 0.7071752369554196
        let warp = tan(.pi * cutoff / Double(sampleRate))
        let shelfGain = pow(10.0, gain / 20.0)
        let bandGain = pow(shelfGain, 0.4996667741545416)
        let norm = 1.0 + warp / quality + warp * warp
        return Biquad(
            feedforward0: (shelfGain + bandGain * warp / quality + warp * warp) / norm,
            feedforward1: 2.0 * (warp * warp - shelfGain) / norm,
            feedforward2: (shelfGain - bandGain * warp / quality + warp * warp) / norm,
            feedback1: 2.0 * (warp * warp - 1.0) / norm,
            feedback2: (1.0 - warp / quality + warp * warp) / norm
        )
    }

    private static func kWeightHighPass(sampleRate: Int) -> Biquad {
        let cutoff = 38.13547087602444
        let quality = 0.5003270373238773
        let warp = tan(.pi * cutoff / Double(sampleRate))
        let norm = 1.0 + warp / quality + warp * warp
        return Biquad(
            feedforward0: 1.0,
            feedforward1: -2.0,
            feedforward2: 1.0,
            feedback1: 2.0 * (warp * warp - 1.0) / norm,
            feedback2: (1.0 - warp / quality + warp * warp) / norm
        )
    }

    private static let interpolatorPhases: [[Double]] = {
        let tapCount = 49
        let factor = 4
        let center = Double(tapCount - 1) / 2.0
        var prototype = [Double](repeating: 0, count: tapCount)
        for tap in 0 ..< tapCount {
            let offset = Double(tap) - center
            let sinc = offset == 0 ? 1.0 : sin(.pi * offset / Double(factor)) / (.pi * offset / Double(factor))
            let window = 0.5 - 0.5 * cos(2 * .pi * Double(tap) / Double(tapCount - 1))
            prototype[tap] = sinc * window
        }
        var phases: [[Double]] = []
        for phase in 1 ..< factor {
            var coefficients: [Double] = []
            var source = phase
            while source < prototype.count {
                coefficients.append(prototype[source])
                source += factor
            }
            phases.append(normalizedToUnitDCGain(coefficients))
        }
        return phases
    }()

    private static func normalizedToUnitDCGain(_ coefficients: [Double]) -> [Double] {
        let sum = coefficients.reduce(0, +)
        return sum == 0 ? coefficients : coefficients.map { $0 / sum }
    }
}
