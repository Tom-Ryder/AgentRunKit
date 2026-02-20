@testable import AgentRunKit
import Testing

@Suite struct ReasoningDetailAccumulatorTests {
    @Test
    func emptyAccumulatorProducesEmptyArray() {
        let acc = ReasoningDetailAccumulator()
        #expect(acc.isEmpty)
        #expect(acc.consolidated() == [])
    }

    @Test
    func anthropicFragmentsConsolidateWithSignature() {
        var acc = ReasoningDetailAccumulator()

        let opening: JSONValue = .object([
            "type": .string("reasoning.text"),
            "text": .string(""),
            "signature": .string(""),
            "format": .string("anthropic-claude-v1"),
            "index": .int(0),
        ])
        acc.append([opening])

        let frag1: JSONValue = .object([
            "type": .string("reasoning.text"),
            "text": .string("Hello"),
            "format": .string("anthropic-claude-v1"),
            "index": .int(0),
        ])
        acc.append([frag1])

        let frag2: JSONValue = .object([
            "type": .string("reasoning.text"),
            "text": .string(" world"),
            "format": .string("anthropic-claude-v1"),
            "index": .int(0),
        ])
        acc.append([frag2])

        let closing: JSONValue = .object([
            "type": .string("reasoning.text"),
            "signature": .string("EvEB_real_signature"),
            "format": .string("anthropic-claude-v1"),
            "index": .int(0),
        ])
        acc.append([closing])

        let result = acc.consolidated()
        #expect(result.count == 1)

        guard case let .object(obj) = result[0] else {
            Issue.record("Expected object")
            return
        }
        #expect(obj["type"] == .string("reasoning.text"))
        #expect(obj["text"] == .string("Hello world"))
        #expect(obj["signature"] == .string("EvEB_real_signature"))
        #expect(obj["format"] == .string("anthropic-claude-v1"))
        #expect(obj["index"] == .int(0))
    }

    @Test
    func noSignatureFragmentsOmitSignatureKey() {
        var acc = ReasoningDetailAccumulator()

        let frag1: JSONValue = .object([
            "type": .string("reasoning.text"),
            "text": .string("Think"),
            "format": .string("unknown"),
            "index": .int(0),
        ])
        let frag2: JSONValue = .object([
            "type": .string("reasoning.text"),
            "text": .string("ing..."),
            "format": .string("unknown"),
            "index": .int(0),
        ])
        acc.append([frag1])
        acc.append([frag2])

        let result = acc.consolidated()
        #expect(result.count == 1)

        guard case let .object(obj) = result[0] else {
            Issue.record("Expected object")
            return
        }
        #expect(obj["text"] == .string("Thinking..."))
        #expect(obj["signature"] == nil)
    }

    @Test
    func mixedTypesPreserveEncryptedPassthrough() {
        var acc = ReasoningDetailAccumulator()

        let textFrag: JSONValue = .object([
            "type": .string("reasoning.text"),
            "text": .string("Analysis"),
            "format": .string("google-gemini-v1"),
            "index": .int(0),
        ])
        acc.append([textFrag])

        let encrypted: JSONValue = .object([
            "type": .string("reasoning.encrypted"),
            "data": .string("encrypted_blob"),
            "format": .string("google-gemini-v1"),
            "index": .int(0),
        ])
        acc.append([encrypted])

        let result = acc.consolidated()
        #expect(result.count == 2)

        guard case let .object(textObj) = result[0] else {
            Issue.record("Expected text object first")
            return
        }
        #expect(textObj["type"] == .string("reasoning.text"))
        #expect(textObj["text"] == .string("Analysis"))

        guard case let .object(encObj) = result[1] else {
            Issue.record("Expected encrypted object second")
            return
        }
        #expect(encObj["type"] == .string("reasoning.encrypted"))
        #expect(encObj["data"] == .string("encrypted_blob"))
    }

    @Test
    func multipleIndicesProduceSeparateBlocks() {
        var acc = ReasoningDetailAccumulator()

        acc.append([
            .object([
                "type": .string("reasoning.text"),
                "text": .string("Block zero"),
                "format": .string("unknown"),
                "index": .int(0),
            ]),
        ])
        acc.append([
            .object([
                "type": .string("reasoning.text"),
                "text": .string("Block one"),
                "format": .string("unknown"),
                "index": .int(1),
            ]),
        ])

        let result = acc.consolidated()
        #expect(result.count == 2)

        guard case let .object(first) = result[0],
              case let .object(second) = result[1]
        else {
            Issue.record("Expected two objects")
            return
        }
        #expect(first["text"] == .string("Block zero"))
        #expect(first["index"] == .int(0))
        #expect(second["text"] == .string("Block one"))
        #expect(second["index"] == .int(1))
    }

    @Test
    func nonObjectValuesPassThrough() {
        var acc = ReasoningDetailAccumulator()
        acc.append([.string("unexpected")])
        acc.append([.int(42)])

        let result = acc.consolidated()
        #expect(result.count == 2)
        #expect(result[0] == .string("unexpected"))
        #expect(result[1] == .int(42))
    }

    @Test
    func emptyTextFragmentsDoNotContributeToOutput() {
        var acc = ReasoningDetailAccumulator()

        acc.append([
            .object([
                "type": .string("reasoning.text"),
                "text": .string(""),
                "format": .string("anthropic-claude-v1"),
                "index": .int(0),
            ]),
        ])
        acc.append([
            .object([
                "type": .string("reasoning.text"),
                "text": .string("Real content"),
                "format": .string("anthropic-claude-v1"),
                "index": .int(0),
            ]),
        ])
        acc.append([
            .object([
                "type": .string("reasoning.text"),
                "text": .string(""),
                "format": .string("anthropic-claude-v1"),
                "index": .int(0),
            ]),
        ])

        let result = acc.consolidated()
        #expect(result.count == 1)
        guard case let .object(obj) = result[0] else {
            Issue.record("Expected object")
            return
        }
        #expect(obj["text"] == .string("Real content"))
    }
}
