import AgentRunKit
import Foundation

struct EmptyParameters: Codable, SchemaProviding {}

struct ListFilesParameters: Codable, SchemaProviding {
    let limit: Int?
}

struct ReadFileParameters: Codable, SchemaProviding {
    let path: String
}

struct GrepParameters: Codable, SchemaProviding {
    let query: String
    let regex: Bool?
    let limit: Int?
}

struct GlobParameters: Codable, SchemaProviding {
    let pattern: String
    let limit: Int?
}

struct WriteFileParameters: Codable, SchemaProviding {
    let path: String
    let content: String
}

struct EditFileParameters: Codable, SchemaProviding {
    let path: String
    let oldString: String
    let newString: String
    let replaceAll: Bool?
}

struct MultiEditParameters: Codable, SchemaProviding {
    let path: String
    let edits: [TextEdit]
}

struct TextEdit: Codable, Equatable, SchemaProviding {
    let oldString: String
    let newString: String
    let replaceAll: Bool?
}

struct RunCommandParameters: Codable, SchemaProviding {
    let command: String
    let arguments: [String]
    let timeoutSeconds: Int?
}

struct WorkspaceStatus: Codable, Equatable {
    let root: String
    let packageType: String
    let gitStatus: String
}

struct FileList: Codable, Equatable {
    let files: [String]
    let truncated: Bool
}

struct FileContent: Codable, Equatable {
    let path: String
    let content: String
}

struct SearchResult: Codable, Equatable {
    let path: String
    let line: Int
    let text: String
}

struct SearchResults: Codable, Equatable {
    let matches: [SearchResult]
    let truncated: Bool
}

struct FileEditResult: Codable, Equatable {
    let path: String
    let replacements: Int
    let diff: String
}

struct FileWriteResult: Codable, Equatable {
    let path: String
    let bytes: Int
    let diff: String
}
