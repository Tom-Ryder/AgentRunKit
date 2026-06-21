import Foundation

enum PCMSeam {
    static func frameCount(_ duration: Duration, sampleRate: Int) -> Int {
        guard duration > .zero else { return 0 }
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let frames = (seconds * Double(sampleRate)).rounded()
        guard frames >= 1 else { return 0 }
        return Int(min(frames, Double(Int.max / 4)))
    }

    static func fadeGain(step: Int, fade: Int) -> Double {
        let position = (Double(step) + 0.5) / Double(fade)
        return position * position * (3 - 2 * position)
    }

    static func pauseFrames(for boundary: TTSBoundary, sentence: Int, paragraph: Int) -> Int {
        switch boundary {
        case .sentence: sentence
        case .paragraph: paragraph
        case .withinSentence, .end: 0
        }
    }
}
