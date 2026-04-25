import Foundation

struct ReasoningDetailAccumulator {
    private struct TextBlock {
        let template: [String: JSONValue]
        var text = ""
        var signature = ""

        var consolidatedValue: JSONValue {
            var object = template
            object["text"] = .string(text)
            if signature.isEmpty {
                object.removeValue(forKey: "signature")
            } else {
                object["signature"] = .string(signature)
            }
            return .object(object)
        }
    }

    private var textBlocks: [Int: TextBlock] = [:]
    private var otherBlocks: [JSONValue] = []

    var isEmpty: Bool {
        textBlocks.isEmpty && otherBlocks.isEmpty
    }

    mutating func append(_ details: [JSONValue]) {
        for detail in details {
            guard case let .object(dict) = detail,
                  case .string("reasoning.text") = dict["type"]
            else {
                otherBlocks.append(detail)
                continue
            }
            let index: Int = if case let .int(idx) = dict["index"] { idx } else { 0 }

            if textBlocks[index] == nil {
                textBlocks[index] = TextBlock(template: dict)
            }
            if case let .string(text) = dict["text"], !text.isEmpty {
                textBlocks[index]?.text += text
            }
            if case let .string(sig) = dict["signature"], !sig.isEmpty {
                textBlocks[index]?.signature = sig
            }
        }
    }

    func consolidated() -> [JSONValue] {
        var result: [JSONValue] = []
        for index in textBlocks.keys.sorted() {
            guard let block = textBlocks[index] else { continue }
            result.append(block.consolidatedValue)
        }
        result.append(contentsOf: otherBlocks)
        return result
    }
}
