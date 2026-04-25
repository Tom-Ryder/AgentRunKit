import Foundation

extension AnthropicMessageContent {
    var isToolResultOnly: Bool {
        guard case let .blocks(blocks) = self else { return false }
        return !blocks.isEmpty && blocks.allSatisfy(\.isToolResult)
    }

    func applyingCacheControl(ttl: CacheControlTTL?) -> AnthropicMessageContent? {
        switch self {
        case let .text(text):
            return .blocks([.text(text, cacheControl: CacheControl(ttl: ttl))])
        case let .blocks(blocks):
            guard let index = blocks.lastIndex(where: \.supportsCacheControl) else {
                return nil
            }
            var updated = blocks
            updated[index] = updated[index].applyingCacheControl(ttl: ttl)
            return .blocks(updated)
        }
    }
}

extension AnthropicContentBlock {
    var isToolResult: Bool {
        if case .toolResult = self {
            return true
        }
        return false
    }

    var supportsCacheControl: Bool {
        switch self {
        case .text, .toolUse, .toolResult, .image, .document:
            true
        case .thinking, .opaque:
            false
        }
    }

    func applyingCacheControl(ttl: CacheControlTTL?) -> AnthropicContentBlock {
        let cacheControl = CacheControl(ttl: ttl)
        switch self {
        case let .text(text, _):
            return .text(text, cacheControl: cacheControl)
        case let .toolUse(id, name, input, _):
            return .toolUse(id: id, name: name, input: input, cacheControl: cacheControl)
        case let .toolResult(toolUseId, content, isError, _):
            return .toolResult(
                toolUseId: toolUseId,
                content: content,
                isError: isError,
                cacheControl: cacheControl
            )
        case let .image(mediaType, data, _):
            return .image(mediaType: mediaType, data: data, cacheControl: cacheControl)
        case let .document(mediaType, data, _):
            return .document(mediaType: mediaType, data: data, cacheControl: cacheControl)
        case .thinking, .opaque:
            return self
        }
    }
}
