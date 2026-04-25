import Foundation

enum AgentCodeError: Error, Equatable {
    case invalidWorkspace(String)
    case pathEscapesWorkspace(String)
    case deniedPath(String)
    case fileTooLarge(path: String, bytes: Int)
    case binaryFile(String)
    case unreadableText(String)
    case invalidToolLimit(parameter: String, value: Int, allowed: String)
    case emptyEditTarget(String)
    case editTargetNotFound(path: String, target: String)
    case ambiguousEditTarget(path: String, target: String, matches: Int)
    case commandNotAllowed(String)
    case commandTimedOut(String)
    case processFailed(command: String, status: Int32, output: String)
    case missingExecutable(String)
    case invalidBaseURL(String)
}

extension AgentCodeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalidWorkspace(path):
            "Invalid workspace: \(path)"
        case let .pathEscapesWorkspace(path):
            "Path escapes workspace: \(path)"
        case let .deniedPath(path):
            "Path is denied by the workspace policy: \(path)"
        case let .fileTooLarge(path, bytes):
            "File is too large to read: \(path) (\(bytes) bytes)"
        case let .binaryFile(path):
            "File appears to be binary: \(path)"
        case let .unreadableText(path):
            "File is not valid UTF-8 text: \(path)"
        case let .invalidToolLimit(parameter, value, allowed):
            "Invalid \(parameter): \(value). Expected \(allowed)."
        case let .emptyEditTarget(path):
            "Edit target cannot be empty: \(path)"
        case let .editTargetNotFound(path, target):
            "Edit target was not found in \(path): \(target)"
        case let .ambiguousEditTarget(path, target, matches):
            "Edit target matched \(matches) times in \(path): \(target)"
        case let .commandNotAllowed(command):
            "Command is not allowlisted: \(command)"
        case let .commandTimedOut(command):
            "Command timed out: \(command)"
        case let .processFailed(command, status, output):
            "Command failed with exit status \(status): \(command)\n\(output)"
        case let .missingExecutable(name):
            "Executable was not found: \(name)"
        case let .invalidBaseURL(value):
            "OPENAI_BASE_URL is not a valid URL: \(value)"
        }
    }
}
