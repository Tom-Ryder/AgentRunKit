import Foundation

struct ToolCallAccumulator {
    let id: String
    let name: String
    let kind: ToolCallKind
    var arguments: String = ""

    init(id: String, name: String, kind: ToolCallKind = .function) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    func toToolCall() -> ToolCall {
        ToolCall(
            id: id,
            name: name,
            arguments: kind == .function && arguments.isEmpty ? "{}" : arguments,
            kind: kind
        )
    }
}
