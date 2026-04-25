import Foundation

enum Terminal {
    static func printBanner(workspace: String, provider: String) {
        writeLine("")
        writeLine(style("┌──────────────────────────────────────────────┐", .cyan))
        writeLine(style("│ AgentCode                                    │", .bold))
        writeLine(style("│ Interactive coding agent for local projects  │", .dim))
        writeLine(style("└──────────────────────────────────────────────┘", .cyan))
        writeLine("")
        writeKeyValue("Workspace", workspace)
        writeKeyValue("Provider", provider)
        writeLine("")
        writeLine("\(pill("try")) fix the failing tests")
        writeLine("\(pill("help")) /help   \(pill("quit")) /exit")
        writeLine("")
    }

    static func section(_ title: String) {
        writeLine("")
        writeLine(style("━━ \(title.uppercased())", .dim))
    }

    static func writeKeyValue(_ key: String, _ value: String) {
        writeLine("\(style(key.padding(toLength: 10, withPad: " ", startingAt: 0), .dim)) \(value)")
    }

    static func promptPrefix() -> String {
        "\(style("agent-code", .bold)) \(style("›", .cyan)) "
    }

    static func pill(_ value: String, style pillStyle: Style = .cyan) -> String {
        "\(style("[", .dim))\(style(value, pillStyle))\(style("]", .dim))"
    }

    static func clearLine() {
        guard isTTY else { return }
        write("\r\u{001B}[2K", terminator: "")
    }

    static func isInteractiveOutput() -> Bool {
        isTTY
    }

    static func rule(_ title: String? = nil, style ruleStyle: Style = .dim) {
        if let title {
            writeLine(style("─ \(title) " + String(repeating: "─", count: max(0, 58 - title.count)), ruleStyle))
        } else {
            writeLine(style(String(repeating: "─", count: 60), ruleStyle))
        }
    }

    static func style(_ value: String, _ style: Style) -> String {
        guard isTTY else { return value }
        return "\u{001B}[\(style.code)m\(value)\u{001B}[0m"
    }

    static func write(_ value: String, terminator: String = "\n") {
        print(value, terminator: terminator)
        fflush(stdout)
    }

    static func writeLine(_ value: String = "") {
        write(value)
    }

    static func prompt(_ value: String) -> String? {
        write(value, terminator: "")
        return readLine()
    }

    static func interactivePrompt(_ value: String) -> String? {
        guard let tty = FileHandle(forUpdatingAtPath: "/dev/tty") else {
            return prompt(value)
        }
        defer {
            try? tty.close()
        }
        tty.write(Data(value.utf8))
        var bytes: [UInt8] = []
        while true {
            let data = tty.readData(ofLength: 1)
            guard let byte = data.first else {
                return bytes.isEmpty ? nil : String(bytes: bytes, encoding: .utf8)
            }
            if byte == 10 || byte == 13 {
                tty.write(Data("\n".utf8))
                return String(bytes: bytes, encoding: .utf8)
            }
            bytes.append(byte)
        }
    }

    private static var isTTY: Bool {
        isatty(STDOUT_FILENO) == 1
    }
}

enum Style {
    case bold
    case dim
    case cyan
    case green
    case yellow
    case red

    var code: String {
        switch self {
        case .bold:
            "1"
        case .dim:
            "2"
        case .cyan:
            "36"
        case .green:
            "32"
        case .yellow:
            "33"
        case .red:
            "31"
        }
    }
}

enum SlashCommandHelp {
    static let text = """
    Commands

      /help          show this help
      /status        show workspace and session status
      /diff          show the current git diff
      /model         show selected model/provider
      /permissions   show approval policy
      /reset         clear conversation history
      /transcript    write .agent-code-transcript.json in the workspace
      /exit          quit
    """
}

enum PermissionsDescription {
    static let text = """
    Automatic
      workspace_status
      list_files
      read_file
      grep
      glob
      git_diff

    Requires approval
      edit_file
      multi_edit
      write_file
      run_command

    Allowlisted commands
      swift test
      swift build
      npm test
      npm run test
      python -m pytest
      python3 -m pytest
    """
}
