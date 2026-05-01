import Foundation

/// Provider-specific request options for Anthropic reasoning behavior.
public struct AnthropicReasoningOptions: Sendable, Equatable {
    /// Whether reasoning uses Anthropic's manual `thinking` block or the adaptive thinking flow.
    public enum Mode: Sendable, Equatable {
        case manual
        case adaptive
    }

    public let mode: Mode
    public let display: AnthropicThinkingDisplay?

    public init(mode: Mode = .manual, display: AnthropicThinkingDisplay? = nil) {
        self.mode = mode
        self.display = display
    }

    public static let manual = AnthropicReasoningOptions()
    public static let adaptive = AnthropicReasoningOptions(mode: .adaptive)

    public static func adaptive(display: AnthropicThinkingDisplay?) -> AnthropicReasoningOptions {
        AnthropicReasoningOptions(mode: .adaptive, display: display)
    }
}
