import Foundation

struct OutputLimiter {
    let maxCharacters: Int

    init(maxCharacters: Int = 20000) {
        precondition(maxCharacters >= 1, "maxCharacters must be at least 1")
        self.maxCharacters = maxCharacters
    }

    func truncate(_ value: String) -> String {
        guard value.count > maxCharacters else { return value }
        let prefix = value.prefix(maxCharacters)
        return "\(prefix)\n[truncated \(value.count - maxCharacters) characters]"
    }
}
