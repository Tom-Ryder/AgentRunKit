@testable import AgentRunKit
import Foundation

struct ReportContext: ToolContext {
    let documentID: String
}

struct FinalizeParams: Codable, SchemaProviding {
    let summary: String

    static var jsonSchema: JSONSchema {
        .object(properties: ["summary": .string()], required: ["summary"])
    }
}

struct FinalizeOutput: Codable {
    let report: String
}

struct LookupParams: Codable, SchemaProviding {
    let query: String

    static var jsonSchema: JSONSchema {
        .object(properties: ["query": .string()], required: ["query"])
    }
}

struct LookupOutput: Codable {
    let matches: Int
}

enum CustomCompletionTestError: Error, Equatable {
    case nonUTF8
    case draftRejected
    case checkpointStorageUnavailable
}

func makeFinalizeTool(
    executor: @escaping @Sendable (FinalizeParams, ReportContext) async throws -> FinalizeOutput
) throws -> Tool<FinalizeParams, FinalizeOutput, ReportContext> {
    try Tool(
        name: "finalize",
        description: "Return the final report. Call it alone once the work is done.",
        executor: executor
    )
}

func makeLookupTool(
    executor: @escaping @Sendable (LookupParams, ReportContext) async throws -> LookupOutput
) throws -> Tool<LookupParams, LookupOutput, ReportContext> {
    try Tool(name: "lookup", description: "Look up supporting material", executor: executor)
}

func report(documentID: String, summary: String) -> FinalizeOutput {
    FinalizeOutput(report: "\(documentID):\(summary)")
}

func encodedReport(documentID: String, summary: String) throws -> String {
    let data = try JSONEncoder().encode(report(documentID: documentID, summary: summary))
    guard let content = String(bytes: data, encoding: .utf8) else {
        throw CustomCompletionTestError.nonUTF8
    }
    return content
}

func toolMessageContents(_ history: [ChatMessage]) -> [String] {
    history.compactMap { message in
        guard case let .tool(_, _, content) = message else { return nil }
        return content
    }
}
