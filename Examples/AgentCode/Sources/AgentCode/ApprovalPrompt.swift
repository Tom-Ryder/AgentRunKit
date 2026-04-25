import AgentRunKit
import Foundation

enum ApprovalPrompt {
    static func resolve(request: ToolApprovalRequest) async -> ToolApprovalDecision {
        Terminal.writeLine("")
        Terminal.rule("approval required", style: .yellow)
        Terminal.writeLine("\(Terminal.pill("review", style: .yellow)) \(Terminal.style(request.toolName, .bold))")
        Terminal.writeLine(Terminal.style(request.toolDescription, .dim))
        Terminal.writeLine("")

        if renderFileEditPreview(for: request) {
            Terminal.rule(style: .yellow)
        } else {
            Terminal.rule("arguments", style: .yellow)
            Terminal.writeLine(request.arguments)
            Terminal.rule(style: .yellow)
        }
        return resolveStandardApproval(request: request)
    }

    private static func resolveStandardApproval(request: ToolApprovalRequest) -> ToolApprovalDecision {
        Terminal.writeLine("")
        Terminal.writeLine(Terminal.style(question(for: request), .bold))
        let response = Terminal.interactivePrompt(prompt(for: request))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch response {
        case "y", "yes":
            return .approve
        default:
            if response == "a" || response == "always", request.toolName == "run_command" {
                return .approveAlways
            }
            return .deny(reason: "User denied \(request.toolName).")
        }
    }

    private static func question(for request: ToolApprovalRequest) -> String {
        switch request.toolName {
        case "edit_file", "multi_edit", "write_file":
            "Approve this file change?"
        case "run_command":
            "Run this command?"
        default:
            "Approve \(request.toolName)?"
        }
    }

    private static func prompt(for request: ToolApprovalRequest) -> String {
        guard request.toolName == "run_command" else {
            return "Approve? [y]es / [n]o: "
        }
        return "Approve? [y]es / [a]lways for this run / [n]o: "
    }

    private static func renderFileEditPreview(for request: ToolApprovalRequest) -> Bool {
        switch request.toolName {
        case "edit_file":
            guard let params = decode(EditFileParameters.self, from: request.arguments) else { return false }
            Terminal.writeKeyValue("Path", params.path)
            Terminal.rule("old", style: .red)
            Terminal.writeLine(preview(params.oldString))
            Terminal.rule("new", style: .green)
            Terminal.writeLine(preview(params.newString))
            return true
        case "multi_edit":
            guard let params = decode(MultiEditParameters.self, from: request.arguments) else { return false }
            Terminal.writeKeyValue("Path", params.path)
            for (index, edit) in params.edits.enumerated() {
                Terminal.rule("edit \(index + 1) old", style: .red)
                Terminal.writeLine(preview(edit.oldString))
                Terminal.rule("edit \(index + 1) new", style: .green)
                Terminal.writeLine(preview(edit.newString))
            }
            return true
        case "write_file":
            guard let params = decode(WriteFileParameters.self, from: request.arguments) else { return false }
            Terminal.writeKeyValue("Path", params.path)
            Terminal.rule("content", style: .green)
            Terminal.writeLine(preview(params.content))
            return true
        default:
            return false
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from arguments: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(arguments.utf8))
    }

    private static func preview(_ value: String) -> String {
        let limit = 4000
        guard value.count > limit else { return value }
        let index = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<index]) + "\n... truncated \(value.count - limit) characters ..."
    }
}
