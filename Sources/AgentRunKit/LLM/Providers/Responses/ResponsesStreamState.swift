import Foundation

actor ResponsesStreamCompletionState {
    private(set) var isCompleted = false
    func markCompleted() {
        isCompleted = true
    }
}

actor ResponsesStreamState {
    private var content = ""
    private var reasoning = ""
    private var reasoningDetails: [JSONValue] = []
    private var toolCalls: [Int: ResponsesStreamedToolCall] = [:]
    private var lastSummaryPart: (outputIndex: Int, summaryIndex: Int)?
    private var summaryPartCount = 0

    func summaryPartSeparator(forOutput outputIndex: Int?, summary summaryIndex: Int?) -> String? {
        guard let summaryIndex else { return nil }
        if let outputIndex {
            let current = (outputIndex, summaryIndex)
            defer { lastSummaryPart = current }
            guard let last = lastSummaryPart,
                  current.0 != last.outputIndex || current.1 != last.summaryIndex
            else { return nil }
            return "\n"
        }
        defer { summaryPartCount += 1 }
        return summaryPartCount > 0 ? "\n" : nil
    }

    func record(_ delta: StreamDelta) {
        switch delta {
        case let .content(text):
            content += text
        case let .reasoning(text):
            reasoning += text
        case let .reasoningDetails(details):
            reasoningDetails.append(contentsOf: details)
        case let .toolCallStart(index, id, name, kind):
            toolCalls[index] = ResponsesStreamedToolCall(
                id: id,
                name: name,
                arguments: toolCalls[index]?.arguments ?? "",
                kind: kind
            )
        case let .toolCallDelta(index, arguments):
            let existing = toolCalls[index]
            toolCalls[index] = ResponsesStreamedToolCall(
                id: existing?.id,
                name: existing?.name,
                arguments: (existing?.arguments ?? "") + arguments,
                kind: existing?.kind ?? .function
            )
        case .audioData, .audioTranscript, .audioStarted, .finished:
            break
        }
    }

    func reconciliationDeltas(
        response: ResponsesAPIResponse,
        projection: ResponsesAPIClient.ResponsesTurnProjection
    ) throws -> [StreamDelta] {
        let target = try ResponsesCompletedSemanticTarget(response: response, projection: projection)
        var deltas: [StreamDelta] = []

        guard let reasoningSuffix = utf8Suffix(of: target.reasoning, afterPrefix: reasoning) else {
            throw AgentError.malformedStream(.finalizedSemanticStateDiverged)
        }
        if !reasoningSuffix.isEmpty {
            reasoning += reasoningSuffix
            deltas.append(.reasoning(reasoningSuffix))
        }

        guard target.reasoningDetails.count >= reasoningDetails.count,
              Array(target.reasoningDetails.prefix(reasoningDetails.count)) == reasoningDetails
        else {
            throw AgentError.malformedStream(.finalizedSemanticStateDiverged)
        }
        let reasoningDetailSuffix = Array(target.reasoningDetails.dropFirst(reasoningDetails.count))
        if !reasoningDetailSuffix.isEmpty {
            reasoningDetails += reasoningDetailSuffix
            deltas.append(.reasoningDetails(reasoningDetailSuffix))
        }

        guard let contentSuffix = utf8Suffix(of: target.content, afterPrefix: content) else {
            throw AgentError.malformedStream(.finalizedSemanticStateDiverged)
        }
        if !contentSuffix.isEmpty {
            content += contentSuffix
            deltas.append(.content(contentSuffix))
        }

        let targetIndices = Set(target.toolCalls.keys)
        guard Set(toolCalls.keys).isSubset(of: targetIndices) else {
            throw AgentError.malformedStream(.finalizedSemanticStateDiverged)
        }

        for (index, targetCall) in target.toolCalls.sorted(by: { $0.key < $1.key }) {
            if let existing = toolCalls[index] {
                guard existing.id == nil || existing.id == targetCall.id,
                      existing.name == nil || existing.name == targetCall.name,
                      let argumentsSuffix = utf8Suffix(
                          of: targetCall.arguments,
                          afterPrefix: existing.arguments
                      )
                else {
                    throw AgentError.malformedStream(.finalizedSemanticStateDiverged)
                }
                if existing.id == nil, let id = targetCall.id, let name = targetCall.name {
                    deltas.append(.toolCallStart(index: index, id: id, name: name, kind: targetCall.kind))
                }
                if !argumentsSuffix.isEmpty {
                    toolCalls[index] = ResponsesStreamedToolCall(
                        id: existing.id ?? targetCall.id,
                        name: existing.name ?? targetCall.name,
                        arguments: existing.arguments + argumentsSuffix,
                        kind: existing.kind
                    )
                    deltas.append(.toolCallDelta(index: index, arguments: argumentsSuffix))
                }
            } else if let id = targetCall.id, let name = targetCall.name {
                toolCalls[index] = targetCall
                deltas.append(.toolCallStart(index: index, id: id, name: name, kind: targetCall.kind))
                if !targetCall.arguments.isEmpty {
                    deltas.append(.toolCallDelta(index: index, arguments: targetCall.arguments))
                }
            }
        }

        return deltas
    }
}

private func utf8Suffix(of target: String, afterPrefix prefix: String) -> String? {
    let targetBytes = Array(target.utf8)
    let prefixBytes = Array(prefix.utf8)
    guard targetBytes.starts(with: prefixBytes) else { return nil }
    return String(bytes: targetBytes.dropFirst(prefixBytes.count), encoding: .utf8)
}

struct ResponsesStreamedToolCall: Equatable {
    let id: String?
    let name: String?
    let arguments: String
    let kind: ToolCallKind
}

struct ResponsesCompletedSemanticTarget {
    let content: String
    let reasoning: String
    let reasoningDetails: [JSONValue]
    let toolCalls: [Int: ResponsesStreamedToolCall]

    init(
        response: ResponsesAPIResponse,
        projection: ResponsesAPIClient.ResponsesTurnProjection
    ) throws {
        content = projection.content
        reasoning = projection.reasoning?.content ?? ""
        reasoningDetails = projection.reasoningDetails ?? []

        var indexedToolCalls: [Int: ResponsesStreamedToolCall] = [:]
        for (index, outputItem) in response.output.enumerated() {
            switch outputItem {
            case let .functionCall(call):
                indexedToolCalls[index] = ResponsesStreamedToolCall(
                    id: call.callId,
                    name: call.name,
                    arguments: call.arguments,
                    kind: .function
                )
            case let .opaque(opaque) where opaque.type == "custom_tool_call":
                guard case let .object(fields) = opaque.raw,
                      case let .string(callId) = fields["call_id"],
                      case let .string(name) = fields["name"]
                else { continue }
                let input = if case let .string(text) = fields["input"] { text } else { "" }
                indexedToolCalls[index] = ResponsesStreamedToolCall(
                    id: callId,
                    name: name,
                    arguments: input,
                    kind: .custom
                )
            case let .opaque(opaque)
                where opaque.type == "mcp_call"
                || opaque.type == "computer_call"
                || opaque.type == "apply_patch_call":
                throw AgentError.llmError(.featureUnsupported(
                    provider: "responses",
                    feature: "\(opaque.type) streaming"
                ))
            default:
                continue
            }
        }
        toolCalls = indexedToolCalls
    }
}
