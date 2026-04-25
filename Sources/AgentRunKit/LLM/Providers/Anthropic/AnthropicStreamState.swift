import Foundation

actor AnthropicStreamState {
    enum BlockType { case thinking, text, toolUse, opaque }

    private var blockTypes: [Int: BlockType] = [:]
    private var thinkingText: [Int: String] = [:]
    private var signatures: [Int: String] = [:]
    private var textContent: [Int: String] = [:]
    private var toolIds: [Int: String] = [:]
    private var toolNames: [Int: String] = [:]
    private var toolInputs: [Int: String] = [:]
    private var toolCallIndices: [Int: Int] = [:]
    private var opaqueBlocks: [Int: JSONValue] = [:]
    private var opaqueDeltas: [Int: [JSONValue]] = [:]
    private var hasOpaqueDeltaBlocks = false
    private(set) var toolCallCount: Int = 0
    private(set) var inputUsage: AnthropicUsage?
    private var outputTokens: Int?
    private(set) var isCompleted: Bool = false
    private var maxBlockIndex: Int = -1

    func markCompleted() {
        isCompleted = true
    }

    func setInputUsage(_ usage: AnthropicUsage) {
        inputUsage = usage
    }

    func setOutputTokens(_ tokens: Int) {
        outputTokens = tokens
    }

    func finalUsage() -> TokenUsage {
        TokenUsage(
            input: inputUsage?.inputTokens ?? 0,
            output: outputTokens ?? 0,
            cacheRead: inputUsage?.cacheReadInputTokens,
            cacheWrite: inputUsage?.cacheCreationInputTokens
        )
    }

    func setBlockType(_ index: Int, _ type: BlockType) {
        blockTypes[index] = type
        maxBlockIndex = max(maxBlockIndex, index)
    }

    func blockType(for index: Int) -> BlockType? {
        blockTypes[index]
    }

    func registerToolCall(_ blockIndex: Int) -> Int {
        let toolIndex = toolCallCount
        toolCallIndices[blockIndex] = toolIndex
        toolCallCount += 1
        return toolIndex
    }

    func toolCallIndex(for blockIndex: Int) -> Int? {
        toolCallIndices[blockIndex]
    }

    func appendThinking(_ index: Int, _ text: String) {
        thinkingText[index, default: ""] += text
    }

    func appendSignature(_ index: Int, _ sig: String) {
        signatures[index, default: ""] += sig
    }

    func thinking(for index: Int) -> String? {
        thinkingText[index]
    }

    func signature(for index: Int) -> String? {
        signatures[index]
    }

    func appendTextContent(_ index: Int, _ text: String) {
        textContent[index, default: ""] += text
    }

    func setToolInfo(_ index: Int, id: String, name: String) {
        toolIds[index] = id
        toolNames[index] = name
    }

    func appendToolInput(_ index: Int, _ json: String) {
        toolInputs[index, default: ""] += json
    }

    func setOpaqueBlock(_ index: Int, raw: JSONValue) {
        opaqueBlocks[index] = raw
    }

    func appendOpaqueDelta(_ index: Int, raw: JSONValue) {
        opaqueDeltas[index, default: []].append(raw)
        hasOpaqueDeltaBlocks = true
    }

    func supportsReplayContinuity() -> Bool {
        !hasOpaqueDeltaBlocks
    }

    func finalizedBlocks() throws -> [JSONValue] {
        guard maxBlockIndex >= 0 else { return [] }
        return try (0 ... maxBlockIndex).compactMap { index in
            guard let type = blockTypes[index] else { return nil }
            switch type {
            case .thinking:
                guard let thinking = thinkingText[index],
                      let signature = signatures[index] else { return nil }
                return .object([
                    "type": .string("thinking"),
                    "thinking": .string(thinking),
                    "signature": .string(signature),
                ])
            case .text:
                return .object([
                    "type": .string("text"),
                    "text": .string(textContent[index] ?? ""),
                ])
            case .toolUse:
                guard let id = toolIds[index],
                      let name = toolNames[index] else { return nil }
                let rawInput = toolInputs[index] ?? ""
                let input: JSONValue
                if rawInput.isEmpty {
                    input = .object([:])
                } else {
                    do {
                        input = try JSONDecoder().decode(JSONValue.self, from: Data(rawInput.utf8))
                    } catch {
                        throw AgentError.llmError(.decodingFailed(
                            description: "Failed to decode accumulated tool input JSON: \(rawInput)"
                        ))
                    }
                }
                return .object([
                    "type": .string("tool_use"),
                    "id": .string(id),
                    "name": .string(name),
                    "input": input,
                ])
            case .opaque:
                guard let start = opaqueBlocks[index] else { return nil }
                return start
            }
        }
    }
}
