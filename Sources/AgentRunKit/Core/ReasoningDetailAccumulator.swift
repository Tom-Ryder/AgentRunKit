import Foundation

struct ReasoningDetailAccumulator: Sendable {
    private var textBlocks: [Int: (template: [String: JSONValue], text: String, signature: String)] = [:]
    private var otherBlocks: [JSONValue] = []

    var isEmpty: Bool { textBlocks.isEmpty && otherBlocks.isEmpty }

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
                textBlocks[index] = (template: dict, text: "", signature: "")
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
            guard let (template, text, signature) = textBlocks[index] else { continue }
            var obj = template
            obj["text"] = .string(text)
            if signature.isEmpty {
                obj.removeValue(forKey: "signature")
            } else {
                obj["signature"] = .string(signature)
            }
            result.append(.object(obj))
        }
        result.append(contentsOf: otherBlocks)
        return result
    }
}
